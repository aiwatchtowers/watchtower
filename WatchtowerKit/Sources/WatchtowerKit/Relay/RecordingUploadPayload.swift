import Foundation

/// Lifecycle of one phone recording travelling to the Mac. rawValues are
/// wire format — never rename.
public enum RecordingUploadStatus: String, Codable, Sendable {
    /// Phone saved the record with the audio asset attached; not ingested yet.
    case pending
    /// The hub wrote `.m4a` + `.meta` into the recordings directory — the
    /// phone may now delete its local copy.
    case received
    /// The hub could not ingest (missing asset, write error); the phone keeps
    /// the local copy and may retry with a fresh upload.
    case failed
}

/// Metadata for one phone-recorded audio file relayed to the Mac. The audio
/// itself rides next to this payload as a `CKAsset`
/// (`CloudRecord.assetFileURL`) — a plain record field, so the ~1 MB payload
/// cap that slices live under does not apply.
///
/// Ack pattern mirrors `ActionRequestPayload`: the phone saves the record as
/// `pending`; the desktop rewrites the SAME record as `received`/`failed`
/// (dropping the asset — the rewrite is what frees the iCloud storage); the
/// phone's `RelayFeed` routes the echo and deletes the local file only on
/// `received`.
public struct RecordingUploadPayload: Codable, Equatable, Sendable {
    /// Client-generated recording id (UUID string on the phone).
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let durationSec: Int
    /// Optional display title ("Standup"); nil encodes to an ABSENT key
    /// (the `isError` discipline) so old and new builds interoperate.
    public let titleHint: String?
    /// Encoding descriptor, e.g. "aac-64k-mono". Informational — the Mac's
    /// decode path reads the container, not this string.
    public let sampleFormat: String
    public var status: RecordingUploadStatus
    /// Set by the desktop on `failed` write-backs; absent otherwise.
    public var errorMessage: String?

    public var recordName: String { "recupload-\(id)" }

    // convertFromSnakeCase maps "duration_sec" -> "durationSec" etc., which
    // matches the synthesized names — but CodingKeys are spelled out anyway
    // so the wire shape is explicit next to the frozen fixtures.
    enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case endedAt
        case durationSec
        case titleHint
        case sampleFormat
        case status
        case errorMessage
    }

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        durationSec: Int,
        titleHint: String? = nil,
        sampleFormat: String,
        status: RecordingUploadStatus = .pending,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.titleHint = titleHint
        self.sampleFormat = sampleFormat
        self.status = status
        self.errorMessage = errorMessage
    }
}
