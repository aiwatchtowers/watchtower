import CryptoKit
import Foundation
import WatchtowerSync

/// The demo's pairing (mobile E2E): a demo hub and the demo phone share fixed link material, so the seed reaches the
/// replica sealed and signed the way a Mac's records do, and the demo runs every read and write through E2E. Every
/// key is derived from a fixed label: the demo holds nothing secret. Demo only: `HubSession` picks these keys for
/// the demo kind over the in-memory transport alone (never over CloudKit). The hub half, which only the seed uses,
/// ships in Release too: the App Store build's demo (`AppRoot.tour`, #174) seeds through it.
extension DemoSeed {
    static let pairingHubID = UUID(uuid: (0xDE, 0x30, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x01))
    static let pairingEpoch: UInt32 = 1

    /// The demo phone's keys: its identity and the link to the demo hub with the epoch's keybox.
    static func phoneKeys() throws -> PhoneKeys {
        let store = try InMemoryPhoneKeyStore(identity: DemoPairing.phoneIdentity)
        try store.saveHubLink(HubLinkKeys(
            hubID: pairingHubID.uuidString,
            hubSigningKey: DemoPairing.hubSigning.publicKey.rawRepresentation,
            hubAgreementKey: DemoPairing.hubAgreement.publicKey.rawRepresentation,
            linkNonce: DemoPairing.linkNonce,
            metaKey: DemoPairing.raw(DemoPairing.metaKey),
            epochs: [EpochKeys(
                epoch: pairingEpoch,
                dataKey: DemoPairing.raw(DemoPairing.dataKey(epoch: pairingEpoch)),
                alertKey: DemoPairing.raw(DemoPairing.alertKey(epoch: pairingEpoch))
            )]
        ))
        return PhoneKeys(store: store, hubID: pairingHubID.uuidString)
    }

    /// The hub's grant as it travels since E2E: the `device_grant-<device_id>` record whose payload is the keybox
    /// (grant only, the demo phone holds its keys already), which the hub seals to the phone.
    static func keyboxRecord(for grant: DeviceGrant, modifiedAt: Date) throws -> CloudRecord {
        let plain = try CloudRecordFactory.record(for: grant, modifiedAt: modifiedAt)
        return CloudRecord(
            recordName: plain.recordName, zone: plain.zone, kind: plain.kind, modifiedAt: modifiedAt,
            payload: try RelayCoder.makeEncoder().encode(Keybox(grant: grant, keys: nil)))
    }

    /// The demo hub sealing over `inner`, its seqs from `seq`.
    static func hubTransport(inner: any CloudSyncTransport & Sendable, seq: SeqAllocator) -> SecureTransport {
        SecureTransport(inner: inner, keys: DemoHubKeys(seq: seq), rollback: InMemoryRollbackGuard())
    }

    /// A demo hub's seqs: a ceiling persisted in `defaults` per demo Mac (`SeqAllocator` blocks), so each
    /// launch's seed is newer than what that Mac's persisted replica holds (it refuses an older `(epoch, seq)` of a
    /// record) whatever the clock does. The first launch with no ceiling starts above `now` in microseconds, where
    /// the seqs of the builds that took them from the clock ended.
    static func hubSeq(defaults: UserDefaults, now: Date, hubID: String = primary.hubID) -> SeqAllocator {
        nonisolated(unsafe) let defaults = defaults
        let key = hubSeqCeilingKey(hubID: hubID)
        let floor = UInt64(max(0, now.timeIntervalSince1970 * 1_000_000))
        return SeqAllocator(
            load: { defaults.string(forKey: key).flatMap(UInt64.init) ?? floor },
            store: { defaults.set(String($0), forKey: key) }
        )
    }

    /// The primary demo Mac keeps the key the single-hub demo used.
    static let hubSeqCeilingKey = "demo.hubSeqCeiling"

    static func hubSeqCeilingKey(hubID: String) -> String {
        hubID == primary.hubID ? hubSeqCeilingKey : "\(hubSeqCeilingKey).\(hubID)"
    }
}

/// Fixed demo key material, derived from labels.
enum DemoPairing {
    static let hubSigning = signingKey("hub-sig")
    static let hubAgreement = agreementKey("hub-kx")
    static let phoneIdentity = DeviceIdentityKeys(signing: signingKey("phone-sig"), agreement: agreementKey("phone-kx"))
    static let linkNonce = Data(bytes("link-nonce").prefix(16))
    static let metaKey = SymmetricKey(data: bytes("meta"))

    static func dataKey(epoch: UInt32) -> SymmetricKey { SymmetricKey(data: bytes("data/\(epoch)")) }
    static func alertKey(epoch: UInt32) -> SymmetricKey { SymmetricKey(data: bytes("alert/\(epoch)")) }

    static func bytes(_ label: String) -> Data {
        Data(SHA256.hash(data: Data("wt-demo/\(label)".utf8)))
    }

    static func raw(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private static func signingKey(_ label: String) -> Curve25519.Signing.PrivateKey {
        // 32 bytes by construction: any 32-byte seed is a valid Ed25519 private key.
        // swiftlint:disable:next force_try
        try! Curve25519.Signing.PrivateKey(rawRepresentation: bytes(label))
    }

    private static func agreementKey(_ label: String) -> Curve25519.KeyAgreement.PrivateKey {
        // 32 bytes by construction: any 32-byte scalar is a valid X25519 private key.
        // swiftlint:disable:next force_try
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes(label))
    }
}

/// The demo hub's `SecureKeyProvider`: one epoch, the demo phone linked.
final class DemoHubKeys: SecureKeyProvider, @unchecked Sendable {
    let role: SecureRole = .hub(hubID: DemoSeed.pairingHubID)
    private let seq: SeqAllocator

    init(seq: SeqAllocator) {
        self.seq = seq
    }

    private var phoneID: UUID { DemoPairing.phoneIdentity.deviceID }

    func metaKey() throws -> SymmetricKey { DemoPairing.metaKey }
    func currentEpoch() throws -> UInt32 { DemoSeed.pairingEpoch }
    func dataKey(epoch: UInt32) throws -> SymmetricKey { DemoPairing.dataKey(epoch: epoch) }
    func alertKey(epoch: UInt32) throws -> SymmetricKey { DemoPairing.alertKey(epoch: epoch) }

    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        guard deviceID == phoneID else { throw KeyStoreError.corrupt("no relay key") }
        return try KeyDerivation.relayKey(
            agreementPrivate: DemoPairing.hubAgreement, peerPublic: DemoPairing.phoneIdentity.agreement.publicKey,
            linkNonce: DemoPairing.linkNonce, hubID: DemoSeed.pairingHubID, deviceID: deviceID, epoch: epoch,
            direction: direction)
    }

    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool {
        deviceID == phoneID && epoch == DemoSeed.pairingEpoch
    }

    func relayDeviceIDs() throws -> [UUID] { [phoneID] }

    func nextSeq() throws -> UInt64 { try seq.next() }

    func hubSigner() throws -> Curve25519.Signing.PrivateKey { DemoPairing.hubSigning }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { DemoPairing.hubAgreement }

    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        deviceID == phoneID ? DemoPairing.phoneIdentity.agreement.publicKey : nil
    }

    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { throw SecureTransportError.wrongRole }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { throw SecureTransportError.wrongRole }
    func linkNonce() throws -> Data { throw SecureTransportError.wrongRole }
}
