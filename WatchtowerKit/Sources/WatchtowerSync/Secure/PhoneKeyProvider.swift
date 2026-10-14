import CryptoKit
import Foundation

/// The phone's `SecureKeyProvider` over its `PhoneKeyStore` for one linked hub. Relay keys are derived on demand
/// from the device's `identity().agreement`, the stored hub agreement key, the link nonce and the epoch, and cached
/// in memory for this provider's life: a provider belongs to one link (a re-link builds a new one).
/// Hub-only calls throw `SecureTransportError.wrongRole`; a locked keychain surfaces as `KeyStoreError.locked`.
public final class PhoneKeyProvider: SecureKeyProvider, @unchecked Sendable {
    public let role: SecureRole
    private let store: any PhoneKeyStore
    private let hubID: String
    private let hubUUID: UUID
    private let deviceID: UUID
    private let seq: SeqAllocator
    private let lock = NSLock()
    private var relayKeys: [String: SymmetricKey] = [:]

    /// `seq` persists in `replica_meta.envelope_seq_ceiling` (Task 8, F29). Throws `E2EError.badHubID` for a hub id
    /// that is not a UUID, and the store's error when the device id cannot be read (`.locked` before first unlock).
    public init(store: any PhoneKeyStore, hubID: String, seq: SeqAllocator) throws {
        let hubUUID = try WireBytes.hubUUID(hubID)
        // The non-secret copy reads while locked; before the identity ever existed it is created here.
        let deviceID = try store.deviceID() ?? store.identity().deviceID
        self.store = store
        self.hubID = hubID
        self.hubUUID = hubUUID
        self.deviceID = deviceID
        self.seq = seq
        self.role = .phone(hubID: hubUUID, deviceID: deviceID)
    }

    private func link() throws -> HubLinkKeys {
        guard let link = try store.hubLink(hubID) else { throw SecureTransportError.keysUnavailable }
        return link
    }

    private func epochKeys(_ epoch: UInt32) throws -> EpochKeys {
        guard let keys = try link().epochs.first(where: { $0.epoch == epoch }) else {
            throw SecureTransportError.keysUnavailable
        }
        return keys
    }

    public func metaKey() throws -> SymmetricKey {
        guard let meta = try link().metaKey else { throw SecureTransportError.keysUnavailable }
        return SymmetricKey(data: meta)
    }

    /// The newest epoch of the stored keybox; 0 before the first keybox (only the hello is sealed then).
    public func currentEpoch() throws -> UInt32 {
        try link().epochs.last?.epoch ?? 0
    }

    public func dataKey(epoch: UInt32) throws -> SymmetricKey {
        SymmetricKey(data: try epochKeys(epoch).dataKey)
    }

    public func alertKey(epoch: UInt32) throws -> SymmetricKey {
        SymmetricKey(data: try epochKeys(epoch).alertKey)
    }

    public func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey {
        guard deviceID == self.deviceID else { throw SecureTransportError.wrongRole }
        let cacheKey = "\(direction.rawValue)/\(epoch)"
        if let cached = lock.withLock({ relayKeys[cacheKey] }) { return cached }
        let link = try link()
        let identity = try store.identity()
        let key = try KeyDerivation.relayKey(
            agreementPrivate: identity.agreement, peerPublic: try hubAgreementPublicKey(link),
            linkNonce: link.linkNonce, hubID: hubUUID, deviceID: deviceID, epoch: epoch, direction: direction)
        lock.withLock { relayKeys[cacheKey] = key }
        return key
    }

    /// Any epoch of the phone's own relay keys: they are pairwise ECDH with the hub, so only the hub (h2p) or
    /// this phone (its own p2h) can have sealed under them. The D10 window is the hub's rule.
    public func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool {
        deviceID == self.deviceID
    }

    public func relayDeviceIDs() throws -> [UUID] { [deviceID] }

    public func nextSeq() throws -> UInt64 { try seq.next() }

    public func hubSigner() throws -> Curve25519.Signing.PrivateKey { throw SecureTransportError.wrongRole }
    public func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey { throw SecureTransportError.wrongRole }
    public func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey? {
        throw SecureTransportError.wrongRole
    }

    public func deviceSigner() throws -> Curve25519.Signing.PrivateKey { try store.identity().signing }

    public func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey {
        try hubAgreementPublicKey(link())
    }

    public func linkNonce() throws -> Data { try link().linkNonce }

    private func hubAgreementPublicKey(_ link: HubLinkKeys) throws -> Curve25519.KeyAgreement.PublicKey {
        do { return try Curve25519.KeyAgreement.PublicKey(rawRepresentation: link.hubAgreementKey) } catch {
            throw KeyStoreError.corrupt("hub agreement key does not parse")
        }
    }
}
