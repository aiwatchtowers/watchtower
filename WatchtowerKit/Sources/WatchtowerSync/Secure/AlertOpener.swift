import CryptoKit
import Foundation
import os

/// What an `ask_alert` record carries (`AskAlertSlice.Payload` on the hub): enough for the notification's title and
/// body, nothing more. Keys are the hub's RelayCoder snake_case ones, spelled out so no key strategy is needed.
public struct AskAlertPayload: Decodable, Equatable, Sendable {
    public let askID: Int64
    public let workbenchID: Int64
    public let workbenchName: String
    public let sessionID: Int64?
    public let kind: String
    public let title: String
    /// The notification offers the one-tap answer (`ASK_QUICK`).
    public let quick: Bool

    public init(
        askID: Int64, workbenchID: Int64, workbenchName: String, sessionID: Int64?, kind: String, title: String, quick: Bool
    ) {
        self.askID = askID
        self.workbenchID = workbenchID
        self.workbenchName = workbenchName
        self.sessionID = sessionID
        self.kind = kind
        self.title = title
        self.quick = quick
    }

    enum CodingKeys: String, CodingKey {
        case askID = "ask_id"
        case workbenchID = "workbench_id"
        case workbenchName = "workbench_name"
        case sessionID = "session_id"
        case kind, title, quick
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
    public func open(wireName: String, envelope: Data) -> AskAlertPayload? {
        do {
            return try payload(wireName: wireName, envelope: envelope)
        } catch {
            Self.logger.notice("ask alert \(wireName, privacy: .public) not opened: \(Self.code(error), privacy: .public)")
            return nil
        }
    }

    /// Throws the envelope's `EnvelopeError`, `SecureTransportError.keysUnavailable` for an epoch the material does
    /// not hold, and `EnvelopeError.frameMalformed` for a frame of another kind or a payload that does not decode.
    public func payload(wireName: String, envelope: Data) throws -> AskAlertPayload {
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
        do { return try JSONDecoder().decode(AskAlertPayload.self, from: frame.payload) } catch {
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
