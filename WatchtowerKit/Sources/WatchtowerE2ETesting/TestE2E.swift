import CryptoKit
import Foundation
import WatchtowerSync

/// One fixed test pairing (F25): a hub and a phone that share link material, plus a stranger phone the hub has never
/// linked. Every key is derived from fixed test bytes, so runs are reproducible; nothing here is a real key.
/// Each `hub()`/`phone()` call returns fresh state (its own store, epoch, seq and lock flags) over the same pairing.
/// Linked only by test targets; public API of `WatchtowerSync` only.
public enum TestE2E {
    public static let hubID = UUID(uuid: (0xE2, 0xE0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x01))
    public static let hubSigningKey = signingKey("hub-sig")
    public static let hubAgreementKey = agreementKey("hub-kx")
    public static let deviceIdentity = DeviceIdentityKeys(signing: signingKey("phone-sig"), agreement: agreementKey("phone-kx"))
    public static let strangerIdentity = DeviceIdentityKeys(
        signing: signingKey("stranger-sig"), agreement: agreementKey("stranger-kx"))
    public static var deviceID: UUID { deviceIdentity.deviceID }
    public static var strangerDeviceID: UUID { strangerIdentity.deviceID }
    public static let linkNonce = Data(bytes("link-nonce").prefix(16))
    public static let metaKey = SymmetricKey(data: bytes("meta"))

    public static func dataKey(epoch: UInt32) -> SymmetricKey { SymmetricKey(data: bytes("data/\(epoch)")) }
    public static func alertKey(epoch: UInt32) -> SymmetricKey { SymmetricKey(data: bytes("alert/\(epoch)")) }

    /// The hub, with the paired phone linked. `epoch` is its current epoch; seqs start at `firstSeq`.
    public static func hub(epoch: UInt32 = 1, firstSeq: UInt64 = 1) -> TestHubKeyProvider {
        TestHubKeyProvider(epoch: epoch, firstSeq: firstSeq, devices: [deviceIdentity])
    }

    /// An in-memory phone store holding `identity` and the link to the test hub with keyboxes for `epochs`.
    public static func phoneStore(identity: DeviceIdentityKeys = deviceIdentity, epochs: [UInt32] = [1]) throws
        -> InMemoryPhoneKeyStore {
        let store = try InMemoryPhoneKeyStore(identity: identity)
        try store.saveHubLink(HubLinkKeys(
            hubID: hubID.uuidString,
            hubSigningKey: hubSigningKey.publicKey.rawRepresentation,
            hubAgreementKey: hubAgreementKey.publicKey.rawRepresentation,
            linkNonce: linkNonce,
            metaKey: raw(metaKey),
            epochs: epochs.map { EpochKeys(epoch: $0, dataKey: raw(dataKey(epoch: $0)), alertKey: raw(alertKey(epoch: $0))) }))
        return store
    }

    /// The paired phone (a fresh store unless one is given); seqs start at `firstSeq`.
    public static func phone(store: InMemoryPhoneKeyStore? = nil, firstSeq: UInt64 = 1) throws -> PhoneKeyProvider {
        try PhoneKeyProvider(store: store ?? phoneStore(), hubID: hubID.uuidString, seq: seqAllocator(firstSeq))
    }

    /// A phone with the hub's link material but an identity the hub never linked.
    public static func stranger(firstSeq: UInt64 = 1) throws -> PhoneKeyProvider {
        try PhoneKeyProvider(
            store: phoneStore(identity: strangerIdentity), hubID: hubID.uuidString, seq: seqAllocator(firstSeq))
    }

    /// The paired phone's replica opener over `store` (a fresh paired store when nil).
    public static func opener(store: InMemoryPhoneKeyStore? = nil) throws -> EnvelopeReplicaOpener {
        EnvelopeReplicaOpener(hubID: hubID.uuidString, deviceID: deviceID, keys: try store ?? phoneStore())
    }

    /// A transport that seals as `keys` (the test hub) over `inner`; DataZone reads pass through untouched, so a
    /// replica hydrating from it receives the hub's envelopes exactly as CloudKit would hand them over.
    public static func hubTransport(
        _ keys: TestHubKeyProvider = hub(),
        inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport()
    ) -> SecureTransport {
        SecureTransport(inner: inner, keys: keys, rollback: InMemoryRollbackGuard())
    }

    /// A transport that seals and opens as the paired phone over `inner`: the phone's own p2h envelopes and the
    /// hub's h2p echoes open, so tests drive the outbox, the uploader and the relay feed exactly as on a device.
    public static func phoneTransport(
        _ keys: PhoneKeyProvider,
        inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport()
    ) -> SecureTransport {
        SecureTransport(inner: inner, keys: keys, rollback: InMemoryRollbackGuard())
    }

    /// A plain `device_grant-<deviceID>` record whose payload is the RelayCoder `Keybox` (grant only) the hub seals
    /// as `keybox-<deviceID>`.
    public static func keyboxRecord(deviceID: UUID = deviceID, modifiedAt: Date) throws -> CloudRecord {
        let grant = DeviceGrant(
            deviceID: deviceID.uuidString, hubID: hubID.uuidString, name: "Acme iPhone", scope: .private, linked: true,
            linkedAt: modifiedAt, typingAllowed: false, startSessionsAllowed: true, decidedAt: modifiedAt)
        return CloudRecord(
            recordName: SliceKind.deviceGrant.recordName(id: deviceID.uuidString), zone: .data,
            kind: SliceKind.deviceGrant.rawValue, modifiedAt: modifiedAt,
            payload: try RelayCoder.makeEncoder().encode(Keybox(grant: grant, keys: nil)))
    }

    /// A DataZone envelope sealed directly (no `SecureTransport` kind check): a kind this build does not know, an
    /// exact `(epoch, seq)`, another hub, another signer. `wireName` defaults to the hub's opaque name of the record.
    public static func sealedDataRecord(
        _ plain: CloudRecord,
        wireName: String? = nil,
        epoch: UInt32 = 1,
        seq: UInt64,
        hubID: UUID = hubID,
        signer: Curve25519.Signing.PrivateKey = hubSigningKey
    ) throws -> CloudRecord {
        let wire = try wireName ?? hubTransport().wireName(plain: plain.recordName, zone: .data)
        let frame = InnerFrame(
            kind: plain.kind, id: plain.recordName, notifyLevel: plain.notifyLevel, asset: plain.asset,
            payload: plain.payload)
        let envelope = try EnvelopeSealer.sealSymmetric(
            frame, envelopeClass: .data, key: dataKey(epoch: epoch), hubID: hubID, senderID: hubID, epoch: epoch,
            seq: seq, context: EnvelopeContext(zone: .data, wireName: wire), signer: signer)
        return CloudRecord(
            recordName: wire, zone: .data, kind: WireKind.envelope, modifiedAt: plain.modifiedAt, payload: envelope,
            assetFileURL: plain.assetFileURL)
    }

    // MARK: - Helpers

    static func seqAllocator(_ firstSeq: UInt64) -> SeqAllocator {
        SeqAllocator(load: { firstSeq }, store: { _ in })
    }

    static func bytes(_ label: String) -> Data {
        Data(SHA256.hash(data: Data("wt-test/\(label)".utf8)))
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

/// The test hub's `SecureKeyProvider`: mutable epoch, D10 window, linked devices and lock state.
public final class TestHubKeyProvider: SecureKeyProvider, @unchecked Sendable {
    public let role: SecureRole = .hub(hubID: TestE2E.hubID)
    private let lock = NSLock()
    private var epoch: UInt32
    private var previousAccepted = true
    private var locked = false
    private var seq: UInt64
    private var devices: [UUID: Curve25519.KeyAgreement.PublicKey] = [:]

    init(epoch: UInt32, firstSeq: UInt64, devices: [DeviceIdentityKeys]) {
        self.epoch = epoch
        self.seq = firstSeq
        for device in devices { self.devices[device.deviceID] = device.agreement.publicKey }
    }

    public var currentEpochValue: UInt32 {
        get { lock.withLock { epoch } }
        set { lock.withLock { epoch = newValue } }
    }

    /// D10: whether the previous epoch's relay envelopes are still accepted.
    public var acceptsPreviousEpoch: Bool {
        get { lock.withLock { previousAccepted } }
        set { lock.withLock { previousAccepted = newValue } }
    }

    /// Every secret read throws `KeyStoreError.locked`.
    public var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    public func link(_ identity: DeviceIdentityKeys) {
        lock.withLock { devices[identity.deviceID] = identity.agreement.publicKey }
    }

    public func unlink(_ deviceID: UUID) {
        lock.withLock { devices[deviceID] = nil }
    }

    private func unlocked() throws {
        if isLocked { throw KeyStoreError.locked }
    }

    public func metaKey() throws -> SymmetricKey {
        try unlocked()
        return TestE2E.metaKey
    }

    public func currentEpoch() throws -> UInt32 { currentEpochValue }

    public func dataKey(epoch: UInt32) throws -> SymmetricKey {
        try unlocked()
        return TestE2E.dataKey(epoch: epoch)
    }

    public func alertKey(epoch: UInt32) throws -> SymmetricKey {
        try unlocked()
        return TestE2E.alertKey(epoch: epoch)
    }

    public func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        try unlocked()
        guard let peer = lock.withLock({ devices[deviceID] }) else { throw KeyStoreError.corrupt("no relay key") }
        return try KeyDerivation.relayKey(
            agreementPrivate: TestE2E.hubAgreementKey, peerPublic: peer, linkNonce: TestE2E.linkNonce,
            hubID: TestE2E.hubID, deviceID: deviceID, epoch: epoch, direction: direction)
    }

    public func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool {
        lock.withLock {
            guard devices[deviceID] != nil else { return false }
            return epoch == self.epoch || (previousAccepted && self.epoch > 0 && epoch == self.epoch - 1)
        }
    }

    public func relayDeviceIDs() throws -> [UUID] {
        lock.withLock { devices.keys.sorted { $0.uuidString < $1.uuidString } }
    }

    public func nextSeq() throws -> UInt64 {
        lock.withLock {
            defer { seq += 1 }
            return seq
        }
    }

    public func hubSigner() throws -> Curve25519.Signing.PrivateKey {
        try unlocked()
        return TestE2E.hubSigningKey
    }

    public func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey {
        try unlocked()
        return TestE2E.hubAgreementKey
    }

    public func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        lock.withLock { devices[deviceID] }
    }

    public func deviceSigner() throws -> Curve25519.Signing.PrivateKey { throw SecureTransportError.wrongRole }
    public func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey { throw SecureTransportError.wrongRole }
    public func linkNonce() throws -> Data { throw SecureTransportError.wrongRole }
}
