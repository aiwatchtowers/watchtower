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
    /// When a newer epoch joined the Keychain (`HubLinkKeys.stampingSuperseded`); nil for the newest and for an
    /// epoch stored before the stamp existed (an absent key: such items decode, and an unstamped epoch encodes as
    /// they did).
    public var supersededAt: Date?
    /// This epoch's `wt/relay/v2/` relay keys, derived from the keybox's `relay_kx` (relay client Phase 5); nil
    /// means the static `wt/relay/v1/` keys. Kept and dropped with the epoch; absent in an item from an older build.
    public var relayKeys: EpochRelayKeys?

    public init(epoch: UInt32, dataKey: Data, alertKey: Data, supersededAt: Date? = nil, relayKeys: EpochRelayKeys? = nil) {
        self.epoch = epoch
        self.dataKey = dataKey
        self.alertKey = alertKey
        self.supersededAt = supersededAt
        self.relayKeys = relayKeys
    }
}

/// One epoch's stored ephemeral relay keys, one per direction, 32 bytes each.
public struct EpochRelayKeys: Codable, Equatable, Sendable {
    public let p2h: Data
    public let h2p: Data

    public init(p2h: Data, h2p: Data) {
        self.p2h = p2h
        self.h2p = h2p
    }

    public func key(_ direction: RelayDirection) -> Data {
        switch direction {
        case .phoneToHub: return p2h
        case .hubToPhone: return h2p
        }
    }
}

/// An X25519 pair the phone draws for the weekly relay keys (relay client Phase 5), raw 32 bytes each: the
/// offered one goes out on `epoch_ack.next_kx`, and becomes the current one when a keybox answers it.
public struct EphemeralKey: Codable, Equatable, Sendable {
    public let publicKey: Data
    public let privateKey: Data

    public init(publicKey: Data, privateKey: Data) {
        self.publicKey = publicKey
        self.privateKey = privateKey
    }

    public static func generate() -> Self {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Self(publicKey: key.publicKey.rawRepresentation, privateKey: key.rawRepresentation)
    }

    /// The private key, checked against `publicKey`: whoever uses the key also puts `publicKey` in a transcript,
    /// so halves that disagree are corrupt, never used.
    public func agreementKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey),
              key.publicKey.rawRepresentation == publicKey
        else { throw KeyStoreError.corrupt("an ephemeral key's halves do not match") }
        return key
    }
}

public struct HubLinkKeys: Codable, Equatable, Sendable {
    public let hubID: String
    public let hubSigningKey: Data
    public let hubAgreementKey: Data
    public let linkNonce: Data
    public var metaKey: Data?
    /// Newest last; `saveHubLink` keeps `retained(now:)`.
    public var epochs: [EpochKeys]
    /// The ephemeral key the hub's newest keybox answered (relay client Phase 5); nil before the first answer.
    public var currentKX: EphemeralKey?
    /// The ephemeral key offered on the last `epoch_ack` and not answered yet; a keybox naming it promotes it.
    public var offeredKX: EphemeralKey?

    /// The most epochs kept, whatever their age (relay client Phase 3: three switches in a week keep four).
    public static let maxEpochs = 8
    /// How long an epoch is kept after a newer one arrived: the hub retires an epoch after 7 days (ask #843, "7 days
    /// everywhere", in place of sim rule 14's 14), so a phone keeping it longer would hold keys nobody uses.
    public static let previousEpochGrace: TimeInterval = 7 * 86_400

    public init(
        hubID: String,
        hubSigningKey: Data,
        hubAgreementKey: Data,
        linkNonce: Data,
        metaKey: Data? = nil,
        epochs: [EpochKeys] = [],
        currentKX: EphemeralKey? = nil,
        offeredKX: EphemeralKey? = nil
    ) {
        self.hubID = hubID
        self.hubSigningKey = hubSigningKey
        self.hubAgreementKey = hubAgreementKey
        self.linkNonce = linkNonce
        self.metaKey = metaKey
        self.epochs = epochs
        self.currentKX = currentKX
        self.offeredKX = offeredKX
    }
}

extension HubLinkKeys {
    /// The epochs kept at `now`: the newest; every unstamped epoch (stored before this build: stamped on the next
    /// merge, never dropped before it); every epoch superseded less than `previousEpochGrace` ago. Then the newest
    /// `maxEpochs` of those, oldest first.
    public func retained(now: Date) -> HubLinkKeys {
        let sorted = epochs.sorted { $0.epoch < $1.epoch }
        let newest = sorted.last?.epoch
        let kept = sorted.filter { keys in
            guard keys.epoch != newest, let supersededAt = keys.supersededAt else { return true }
            return now.timeIntervalSince(supersededAt) < Self.previousEpochGrace
        }
        var copy = self
        copy.epochs = Array(kept.suffix(Self.maxEpochs))
        return copy
    }

    /// This merged link with each epoch's `supersededAt`: the stamp `previous` holds for that epoch, else `now` for
    /// every epoch but the newest (the previous newest when a newer one arrived, and any epoch stored before the
    /// stamp existed); the newest is never stamped.
    public func stampingSuperseded(from previous: HubLinkKeys, now: Date) -> HubLinkKeys {
        let stamps = Dictionary(previous.epochs.map { ($0.epoch, $0.supersededAt) }) { first, _ in first }
        let newest = epochs.map(\.epoch).max()
        var copy = self
        copy.epochs = epochs.map { keys in
            var stamped = keys
            stamped.supersededAt = keys.epoch == newest ? nil : stamps[keys.epoch].flatMap { $0 } ?? now
            return stamped
        }
        return copy
    }

    /// Whether this link's newest epoch is above `previous`'s (an `epoch_ack` is due on an ordered hub).
    public func newestEpochRaised(over previous: HubLinkKeys) -> Bool {
        guard let newest = epochs.map(\.epoch).max() else { return false }
        guard let before = previous.epochs.map(\.epoch).max() else { return true }
        return newest > before
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
    /// The identity when one exists, never created (F14: a launch that is not the link flow reads only).
    /// nil when absent; throws `.locked` while locked and `.corrupt` for a half-present identity.
    func existingIdentity() throws -> DeviceIdentityKeys?
    func hubLink(_ hubID: String) throws -> HubLinkKeys?
    /// Also refreshes the two afterFirstUnlock copies (public signing key, alert material).
    func saveHubLink(_ keys: HubLinkKeys) throws
    /// Reads `hubID`'s link, applies `change` and saves the result as `saveHubLink` does, all under the store's
    /// lock, so concurrent writers lose nothing. Returns the stored link; nil, with `change` never called and
    /// nothing written, when there is no link (an unlink is never undone). `change` must not call the store.
    func updateHubLink(_ hubID: String, _ change: (HubLinkKeys) throws -> HubLinkKeys) throws -> HubLinkKeys?
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
    /// The hub's identity when all three items exist, nil when none does; never creates anything. A partial or
    /// unparsable identity throws `.corrupt`, a locked keychain `.locked`.
    func existingHubIdentity(hubID: String) throws -> HubIdentityKeys?
    func deleteHubIdentity(hubID: String) throws
}
