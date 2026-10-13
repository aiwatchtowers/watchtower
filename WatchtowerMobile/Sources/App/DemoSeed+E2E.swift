import CryptoKit
import Foundation
import WatchtowerSync

/// The demo's pairing (mobile E2E Task 16 Step 0, the smallest change that keeps the demo running): a demo hub and
/// the demo phone share fixed link material, so the seed reaches the replica sealed and signed the way a Mac's
/// records do. Every key is derived from a fixed label: the demo holds nothing secret. Task 17 reworks the demo.
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

    /// The demo hub sealing over `inner`. Its seqs start at `firstSeq`, by default the launch time in microseconds,
    /// so a relaunch's seed is newer than the one a persisted replica holds (the replica refuses an older
    /// `(epoch, seq)` of a record).
    static func hubTransport(inner: any CloudSyncTransport & Sendable, firstSeq: UInt64? = nil) -> SecureTransport {
        let first = firstSeq ?? UInt64(max(0, Date().timeIntervalSince1970 * 1_000_000))
        return SecureTransport(inner: inner, keys: DemoHubKeys(firstSeq: first), rollback: InMemoryRollbackGuard())
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
    private let lock = NSLock()
    private var seq: UInt64

    init(firstSeq: UInt64) {
        seq = firstSeq
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

    func nextSeq() throws -> UInt64 {
        lock.withLock {
            defer { seq += 1 }
            return seq
        }
    }

    func hubSigner() throws -> Curve25519.Signing.PrivateKey { DemoPairing.hubSigning }
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { DemoPairing.hubAgreement }

    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        deviceID == phoneID ? DemoPairing.phoneIdentity.agreement.publicKey : nil
    }

    func deviceSigner() throws -> Curve25519.Signing.PrivateKey { throw SecureTransportError.wrongRole }
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { throw SecureTransportError.wrongRole }
    func linkNonce() throws -> Data { throw SecureTransportError.wrongRole }
}
