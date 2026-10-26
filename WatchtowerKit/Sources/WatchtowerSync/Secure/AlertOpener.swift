import CryptoKit
import Foundation
import os

/// What an `ask_alert` record carries (`work_alert` on the hub): one of four work events (ask, permission, session
/// stopped, session failed), enough for the notification's title and body, nothing more. Keys are the hub's
/// RelayCoder snake_case ones, spelled out so no key strategy is needed on either side. The wire kind stays
/// `ask_alert`; an old ask-shaped payload has no `event` and does not decode (the extension shows the generic text).
public struct WorkAlertPayload: Codable, Equatable, Sendable {
    public enum Event: String, Codable, Sendable {
        case ask, permission
        case sessionStopped = "session_stopped"
        case sessionFailed = "session_failed"
    }

    public let event: Event
    /// Stable per occurrence (`WorkAlertKey`); the notification's thread/identifier.
    public let key: String
    public let workbenchID: Int64
    public let workbenchName: String
    public let sessionID: Int64?
    public let askID: Int64?
    public let requestID: Int64?
    /// The notification's title: workbench name, then the session title when there is one.
    public let title: String
    public let body: String
    /// The notification offers the one-tap answer (`ASK_QUICK`).
    public let quick: Bool

    public init(
        event: Event,
        key: String,
        workbenchID: Int64,
        workbenchName: String,
        sessionID: Int64?,
        askID: Int64?,
        requestID: Int64?,
        title: String,
        body: String,
        quick: Bool
    ) {
        self.event = event
        self.key = key
        self.workbenchID = workbenchID
        self.workbenchName = workbenchName
        self.sessionID = sessionID
        self.askID = askID
        self.requestID = requestID
        self.title = title
        self.body = body
        self.quick = quick
    }

    enum CodingKeys: String, CodingKey {
        case event, key, title, body, quick
        case workbenchID = "workbench_id"
        case workbenchName = "workbench_name"
        case sessionID = "session_id"
        case askID = "ask_id"
        case requestID = "request_id"
    }
}

/// The `WorkAlertPayload.key` formats.
public enum WorkAlertKey {
    public static func ask(_ id: Int64) -> String { "ask-\(id)" }

    public static func permission(_ id: Int64) -> String { "perm-\(id)" }

    /// One stop of work, one key: the session and the moment its state was entered, in whole unix milliseconds
    /// rounded to the nearest (a millisecond stamp whose `* 1000` lands a hair under it in floating point keys at
    /// that millisecond, not the one before).
    public static func stop(session: Int64, stateAt: Date) -> String {
        "stop-\(session)-\(Int64((stateAt.timeIntervalSince1970 * 1000).rounded()))"
    }
}

/// Opens an `ask_alert` envelope in the notification extension (mobile E2E spec §2.2, §2.6). It holds only the
/// `AlertMaterial` of the shared alert group (F21): `K_alert` of the epochs the phone keeps (the current one and the
/// previous one, so an alert a rotation resealed without a new signal still opens) and the hub's public signing key.
/// It has no `PhoneKeyStore`, so it cannot reach a private item by construction. Only `.alert` envelopes of the hub,
/// signed by it, with an `ask_alert` frame are opened.
public struct AlertOpener: Sendable {
    private static let logger = Logger(subsystem: "WatchtowerKit", category: "AlertOpener")

    let material: AlertMaterial

    public init(material: AlertMaterial) {
        self.material = material
    }

    /// The payload, or nil on any failure: the extension then delivers the content-free notification unchanged.
    /// Only the failure's code is logged, never key or payload bytes.
    public func open(wireName: String, envelope: Data) -> WorkAlertPayload? {
        do {
            return try payload(wireName: wireName, envelope: envelope)
        } catch {
            Self.logger.notice("ask alert \(wireName, privacy: .public) not opened: \(Self.code(error), privacy: .public)")
            return nil
        }
    }

    /// Throws the envelope's `EnvelopeError`, `SecureTransportError.keysUnavailable` for an epoch the material does
    /// not hold, and `EnvelopeError.frameMalformed` for a frame of another kind or a payload that does not decode.
    public func payload(wireName: String, envelope: Data) throws -> WorkAlertPayload {
        let header = try Envelope.parse(envelope).header
        // Every DataZone envelope is the hub's own: its id is both the hub and the sender id (D7).
        guard header.senderID == header.hubID else { throw EnvelopeError.wrongSender }
        let verifier: Curve25519.Signing.PublicKey
        do { verifier = try Curve25519.Signing.PublicKey(rawRepresentation: material.hubSigningKey) } catch {
            throw KeyStoreError.corrupt("hub signing key does not parse")
        }
        let frame = try EnvelopeSealer.openSymmetric(
            envelope, accepting: [.alert], context: EnvelopeContext(zone: .data, wireName: wireName), verifier: verifier
        ) { header in
            guard let keys = material.epochs.first(where: { $0.epoch == header.epoch }) else {
                throw SecureTransportError.keysUnavailable
            }
            guard keys.alertKey.count == 32 else { throw KeyStoreError.corrupt("alert key is not 32 bytes") }
            return SymmetricKey(data: keys.alertKey)
        }.frame
        guard frame.kind == SliceKind.askAlert.rawValue else { throw EnvelopeError.frameMalformed }
        do { return try JSONDecoder().decode(WorkAlertPayload.self, from: frame.payload) } catch {
            // A DecodingError's description could quote the payload: it surfaces as a code only.
            throw EnvelopeError.frameMalformed
        }
    }

    private static func code(_ error: Error) -> String {
        switch error {
        case let error as EnvelopeError: return String(describing: error)
        case let error as SecureTransportError: return String(describing: error)
        case KeyStoreError.corrupt: return "corrupt"
        case let error as KeyStoreError: return String(describing: error)
        default: return "unexpected"
        }
    }
}
