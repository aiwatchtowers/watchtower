import Foundation
import os

/// Lifecycle of one chat attachment travelling to the hub. rawValues are wire format. The hub rewrites the same
/// record `applied` (with `attachment_id`) or `failed` (with `reason` and `error_message`), dropping the asset.
public enum ChatAttachmentUploadStatus: String, Codable, Sendable {
    case pending
    case applied
    case failed

    /// A status this build does not know decodes as `pending` (inert on the phone), the `ActionStatus` rule.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .pending
    }
}

/// The descriptor of one chat attachment the phone uploads (iPhone chat spec §4.5), the payload of the
/// `chat_attachment` relay record `chatupload-<upload_id>`. The file rides next to it as the record's sealed asset.
/// The Go hub's `internal/hub/actions/chat_attachment.go` reads it; `chat/actions.json` pins both.
public struct ChatAttachmentUploadPayload: Codable, Equatable, Sendable {
    /// The plain name prefix; the hub answers under the same name.
    public static let recordNamePrefix = "chatupload-"

    /// Client-generated upload id (a UUID string on the phone).
    public let uploadID: String
    public let conversationID: Int64
    public let name: String
    public let mime: String
    /// The file's size in bytes.
    public let size: Int64
    /// The linked phone that uploads (the hub fails an upload without a linked device as `device_not_linked`).
    public let deviceID: String?
    /// The hub the phone addressed; nil is not checked.
    public let hubID: String?
    public var status: ChatAttachmentUploadStatus
    /// Set by the hub on `applied`: the id the next `chat_turn` names in `attachment_ids`.
    public var attachmentID: Int64?
    /// Closed code the hub writes on `failed`; one this build does not know decodes as nil.
    public var reason: ActionReason?
    /// What the hub says on `failed`, shown as it is.
    public var errorMessage: String?

    public var recordName: String { Self.recordNamePrefix + uploadID }

    enum CodingKeys: String, CodingKey {
        case uploadID = "uploadId"
        case conversationID = "conversationId"
        case name, mime, size
        case deviceID = "deviceId"
        case hubID = "hubId"
        case status
        case attachmentID = "attachmentId"
        case reason
        case errorMessage
    }

    public init(
        uploadID: String,
        conversationID: Int64,
        name: String,
        mime: String,
        size: Int64,
        deviceID: String? = nil,
        hubID: String? = nil
    ) {
        self.uploadID = uploadID
        self.conversationID = conversationID
        self.name = name
        self.mime = mime
        self.size = size
        self.deviceID = deviceID
        self.hubID = hubID
        self.status = .pending
        self.attachmentID = nil
        self.reason = nil
        self.errorMessage = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uploadID = try c.decode(String.self, forKey: .uploadID)
        conversationID = try c.decode(Int64.self, forKey: .conversationID)
        name = try c.decode(String.self, forKey: .name)
        mime = try c.decode(String.self, forKey: .mime)
        size = try c.decode(Int64.self, forKey: .size)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        hubID = try c.decodeIfPresent(String.self, forKey: .hubID)
        status = try c.decode(ChatAttachmentUploadStatus.self, forKey: .status)
        attachmentID = try c.decodeIfPresent(Int64.self, forKey: .attachmentID)
        reason = try c.decodeIfPresent(String.self, forKey: .reason).flatMap(ActionReason.init(rawValue:))
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

/// The seam through which `RelayFeed` hands `chat_attachment` echoes (`applied` or `failed`) onward, with the
/// `RecordingUploadAcking` delivery contract: called for every decodable non-pending echo before the relay token is
/// stored, so it must be idempotent per record.
public protocol ChatAttachmentAcking: Sendable {
    func applyEcho(_ upload: ChatAttachmentUploadPayload) async throws
}

/// Seals and sends one chat attachment. The file is encrypted to `sealedFile` under a fresh asset key and the
/// descriptor record is sealed with it, as a recording is; only ciphertext leaves the phone. The caller keeps the
/// returned `Sealed` until the echo and sends the same one again on a retry of a lost send; a fresh upload id
/// (Retry after a `failed` echo) is a new record. The hub answers an upload it already stored with the same echo,
/// so a resend never stores a file twice.
public enum ChatAttachmentUploader {
    public struct Sealed: Sendable {
        /// The wire record (kind `wt`, the envelope, the sealed asset attached).
        public let record: CloudRecord
        public let sealedFile: URL
    }

    /// Encrypts `file` to `sealedFile` and seals the descriptor with its asset descriptor. A locked keychain throws
    /// `SecureTransportError.keysUnavailable` before the file is encrypted; a failure leaves no sealed file.
    public static func seal(
        _ payload: ChatAttachmentUploadPayload,
        file: URL,
        sealedFile: URL,
        transport: SecureTransport,
        modifiedAt: Date = Date()
    ) async throws -> Sealed {
        let plain = try CloudRecordFactory.record(for: payload, modifiedAt: modifiedAt, assetFileURL: nil)
        // The opaque name needs `K_meta`: fail before a large file is encrypted for nothing.
        _ = try transport.wireName(for: plain)
        let descriptor = try ChunkedAssetCipher.encryptFile(at: file, to: sealedFile)
        do {
            let wire = try await transport.seal(CloudRecord(
                recordName: plain.recordName, zone: plain.zone, kind: plain.kind, modifiedAt: plain.modifiedAt,
                payload: plain.payload, assetFileURL: sealedFile, asset: descriptor))
            return Sealed(record: wire, sealedFile: sealedFile)
        } catch {
            // The asset key dies with this call, so a sealed file without its envelope is useless.
            try? FileManager.default.removeItem(at: sealedFile)
            throw error
        }
    }

    public static func send(_ sealed: Sealed, transport: SecureTransport) async throws {
        try await transport.saveSealed([sealed.record])
    }
}
