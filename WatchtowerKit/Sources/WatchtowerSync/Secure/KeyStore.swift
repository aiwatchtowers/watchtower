import CryptoKit
import Foundation

/// Keychain accessibility class of an item. Always the `ThisDeviceOnly` variant: no key leaves the device by backup or sync.
public enum KeyAccess: Sendable, Equatable { case whenUnlocked, afterFirstUnlock }

/// Failures of a key store. `locked` is "the key exists but cannot be read right now" and is never folded into
/// "absent" or "authentication failed": callers keep the work and retry after unlock.
public enum KeyStoreError: Error, Equatable {
    case locked
    case missingEntitlement
    case corrupt(String)
    case unexpected(Int32)
}

public protocol KeychainBackend: Sendable {
    /// nil when absent; a device that is locked throws `KeyStoreError.locked`.
    func read(account: String, group: String?) throws -> Data?
    /// Create or replace in place (never delete first: a failed write must not destroy the existing item).
    func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws
    /// Add-only: returns false, changing nothing, when the item already exists. Creation uses this so two creators never clobber.
    func add(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws -> Bool
    func delete(account: String, group: String?) throws
}

public struct DeviceIdentityKeys: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public var deviceID: UUID { KeyDerivation.deviceID(signingPublicKey: signing.publicKey) }

    public init(signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey) {
        self.signing = signing
        self.agreement = agreement
    }
}

public struct EpochKeys: Codable, Equatable, Sendable {
    public let epoch: UInt32
    public let dataKey: Data
    public let alertKey: Data

    public init(epoch: UInt32, dataKey: Data, alertKey: Data) {
        self.epoch = epoch
        self.dataKey = dataKey
        self.alertKey = alertKey
    }
}

public struct HubLinkKeys: Codable, Equatable, Sendable {
    public let hubID: String
    public let hubSigningKey: Data
    public let hubAgreementKey: Data
    public let linkNonce: Data
    public var metaKey: Data?
    /// Newest last, at most `maxEpochs` kept.
    public var epochs: [EpochKeys]

    public static let maxEpochs = 2

    public init(
        hubID: String,
        hubSigningKey: Data,
        hubAgreementKey: Data,
        linkNonce: Data,
        metaKey: Data? = nil,
        epochs: [EpochKeys] = []
    ) {
        self.hubID = hubID
        self.hubSigningKey = hubSigningKey
        self.hubAgreementKey = hubAgreementKey
        self.linkNonce = linkNonce
        self.metaKey = metaKey
        self.epochs = epochs
    }
}

/// What the notification extension can read (F21): K_alert epochs (data keys emptied) and the hub's public signing key.
public struct AlertMaterial: Codable, Equatable, Sendable {
    public let epochs: [EpochKeys]
    public let hubSigningKey: Data

    public init(epochs: [EpochKeys], hubSigningKey: Data) {
        self.epochs = epochs
        self.hubSigningKey = hubSigningKey
    }
}

public protocol PhoneKeyStore: Sendable {
    /// Created on first use (whenUnlocked). Throws `.locked` rather than creating a second identity.
    func identity() throws -> DeviceIdentityKeys
    func hubLink(_ hubID: String) throws -> HubLinkKeys?
    /// Also refreshes the two afterFirstUnlock copies (public signing key, alert material).
    func saveHubLink(_ keys: HubLinkKeys) throws
    func removeHubLink(_ hubID: String) throws
    /// afterFirstUnlock copy of the hub's public signing key: the replica verifies signatures while locked.
    func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey?
    /// afterFirstUnlock, shared access group. nil when absent; throws `.locked`/`.corrupt` (absent vs unavailable stay distinct).
    func alertMaterial(_ hubID: String) throws -> AlertMaterial?
    /// Non-secret copy of the device id, readable while locked. nil before `identity()` first ran.
    func deviceID() throws -> UUID?
}

public struct HubIdentityKeys: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public let wrapKey: SymmetricKey

    public init(signing: Curve25519.Signing.PrivateKey, agreement: Curve25519.KeyAgreement.PrivateKey, wrapKey: SymmetricKey) {
        self.signing = signing
        self.agreement = agreement
        self.wrapKey = wrapKey
    }
}

public protocol HubKeyStore: Sendable {
    /// Loads the hub's identity; creates all three items when none exists. `created` is true when it did.
    func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool)
    func deleteHubIdentity(hubID: String) throws
}
