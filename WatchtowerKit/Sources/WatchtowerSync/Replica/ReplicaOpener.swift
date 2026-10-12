import CryptoKit
import Foundation

/// How the replica checks and opens the hub's DataZone envelopes (mobile E2E spec §2.6). Apply time needs no secret
/// key (the hub's public signing key is `afterFirstUnlock`), so a locked phone still stores and verifies what
/// CloudKit delivers; read time opens with the epoch keys (`whenUnlocked`). A locked keychain surfaces as
/// `KeyStoreError.locked`, never as a failure of the record.
public protocol ReplicaOpening: Sendable {
    /// Apply time, no secret key: parse, check hub id and class, verify the hub signature (public key).
    func verify(wireName: String, envelope: Data) throws -> EnvelopeHeader
    /// Read time: open and return the inner frame. A keybox opens to its `Keybox`, and the frame's payload is
    /// the `grant` JSON, so `device_grant` readers stay unchanged.
    func open(wireName: String, envelope: Data) throws -> InnerFrame
    /// The kind and plain record name of a fixed-name record, without opening it (`heartbeat`, `keybox-<id>`).
    func fixedName(_ wireName: String) -> (kind: String, plainName: String)?
    /// The phone's own `.relayToHub` envelopes (the `pending_actions` overlay, Task 9), under its p2h key.
    func openOwnRelay(wireName: String, envelope: Data) throws -> InnerFrame
}

/// The phone's `ReplicaOpening` over its `PhoneKeyStore`, for one linked hub. Every key is read from the store on
/// each call, never cached: a lock takes effect at once, and a re-pair that changes the hub's signing key for the
/// same hub id is honoured by the very next record (a stale cached key would refuse every record while the token
/// moves on). The public key is an `afterFirstUnlock` item, so the read is cheap.
public final class EnvelopeReplicaOpener: ReplicaOpening {
    private static let dataClasses: Set<EnvelopeClass> = [.data, .alert, .keybox]
    private static let keyboxPrefix = "keybox-"

    private let hubID: String
    private let deviceID: UUID
    private let keys: any PhoneKeyStore

    /// `deviceID` (F13, F14): read from `PhoneKeyStore.deviceID()`, which works while locked; keyboxes for any
    /// other device id are dropped at apply.
    public init(hubID: String, deviceID: UUID, keys: any PhoneKeyStore) {
        self.hubID = hubID
        self.deviceID = deviceID
        self.keys = keys
    }

    // MARK: - Apply time

    public func verify(wireName: String, envelope: Data) throws -> EnvelopeHeader {
        let parsed = try Envelope.parse(envelope)
        let header = parsed.header
        try checkSender(header)
        guard Self.dataClasses.contains(header.envelopeClass) else { throw EnvelopeError.wrongClass(header.envelopeClass) }
        try EnvelopeSealer.verify(parsed, context: Self.context(wireName), key: try hubSigningKey())
        return header
    }

    /// nil for another phone's keybox (F13): every replica in the zone receives every `keybox-<id>`, and only this
    /// device's is a record of this replica; `ReplicaStore.apply` drops the others unread.
    public func fixedName(_ wireName: String) -> (kind: String, plainName: String)? {
        if wireName == HeartbeatPayload.recordName { return (SliceKind.heartbeat.rawValue, wireName) }
        guard wireName.hasPrefix(Self.keyboxPrefix),
              UUID(uuidString: String(wireName.dropFirst(Self.keyboxPrefix.count))) == deviceID
        else { return nil }
        return (SliceKind.deviceGrant.rawValue, SliceKind.deviceGrant.recordName(id: deviceID.uuidString))
    }

    // MARK: - Read time

    public func open(wireName: String, envelope: Data) throws -> InnerFrame {
        let header = try Envelope.parse(envelope).header
        try checkSender(header)
        let context = Self.context(wireName)
        switch header.envelopeClass {
        case .data, .alert:
            let isAlert = header.envelopeClass == .alert
            return try EnvelopeSealer.openSymmetric(
                envelope, accepting: [header.envelopeClass], context: context, verifier: try hubSigningKey()
            ) { opened in
                let epochKeys = try self.epochKeys(opened.epoch)
                return SymmetricKey(data: isAlert ? epochKeys.alertKey : epochKeys.dataKey)
            }.frame
        case .keybox:
            let hubUUID = try WireBytes.hubUUID(hubID)
            let frame = try SealedBox.open(
                envelope, envelopeClass: .keybox, recipient: try keys.identity().agreement,
                info: SealedBox.keyboxInfo(hubID: hubUUID, deviceID: deviceID), context: context,
                verifier: try hubSigningKey()
            ).frame
            let keybox: Keybox
            do { keybox = try RelayCoder.makeDecoder().decode(Keybox.self, from: frame.payload) } catch {
                throw EnvelopeError.frameMalformed
            }
            return InnerFrame(
                kind: frame.kind, id: frame.id, notifyLevel: frame.notifyLevel, asset: frame.asset,
                payload: try RelayCoder.makeEncoder().encode(keybox.grant))
        case .hello, .relayToHub, .relayToPhone:
            throw EnvelopeError.wrongClass(header.envelopeClass)
        }
    }

    public func openOwnRelay(wireName: String, envelope: Data) throws -> InnerFrame {
        let header = try Envelope.parse(envelope).header
        guard header.hubID == (try WireBytes.hubUUID(hubID)) else { throw EnvelopeError.wrongHub }
        guard header.envelopeClass == .relayToHub else { throw EnvelopeError.wrongClass(header.envelopeClass) }
        guard header.senderID == deviceID else { throw EnvelopeError.wrongSender }
        let key = try relayKey(epoch: header.epoch)
        return try EnvelopeSealer.openSymmetric(
            envelope, accepting: [.relayToHub], context: EnvelopeContext(zone: .relay, wireName: wireName), verifier: nil
        ) { _ in key }.frame
    }

    // MARK: - Keys

    private static func context(_ wireName: String) -> EnvelopeContext {
        EnvelopeContext(zone: .data, wireName: wireName)
    }

    /// Every DataZone envelope is the hub's: its id is both the hub id and the sender id (D7).
    private func checkSender(_ header: EnvelopeHeader) throws {
        let hubUUID = try WireBytes.hubUUID(hubID)
        guard header.hubID == hubUUID else { throw EnvelopeError.wrongHub }
        guard header.senderID == hubUUID else { throw EnvelopeError.wrongSender }
    }

    /// The `afterFirstUnlock` copy; absent (no link yet) is `keysUnavailable`, so apply keeps the batch for later.
    private func hubSigningKey() throws -> Curve25519.Signing.PublicKey {
        guard let key = try keys.hubSigningKey(hubID) else { throw SecureTransportError.keysUnavailable }
        return key
    }

    private func link() throws -> HubLinkKeys {
        guard let link = try keys.hubLink(hubID) else { throw SecureTransportError.keysUnavailable }
        return link
    }

    /// An epoch this phone holds no keys for (an older one dropped, a newer keybox not processed yet) is
    /// `keysUnavailable`: the row stays and opens once the keys are there.
    private func epochKeys(_ epoch: UInt32) throws -> EpochKeys {
        guard let keys = try link().epochs.first(where: { $0.epoch == epoch }) else {
            throw SecureTransportError.keysUnavailable
        }
        return keys
    }

    private func relayKey(epoch: UInt32) throws -> SymmetricKey {
        let link = try link()
        let hubPublic: Curve25519.KeyAgreement.PublicKey
        do { hubPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: link.hubAgreementKey) } catch {
            throw KeyStoreError.corrupt("hub agreement key does not parse")
        }
        return try KeyDerivation.relayKey(
            agreementPrivate: try keys.identity().agreement, peerPublic: hubPublic, linkNonce: link.linkNonce,
            hubID: try WireBytes.hubUUID(hubID), deviceID: deviceID, epoch: epoch, direction: .phoneToHub)
    }
}
