import CryptoKit
import Foundation

/// The phone's keys. Secrets are `whenUnlocked`; only the public hub signing key, the device id and the alert material
/// (no data key, no meta key) are `afterFirstUnlock`. Every item but `alert.<hub_id>` goes to `privateGroup` explicitly (F20).
/// No fallback to UserDefaults or files for any key.
public final class KeychainPhoneKeyStore: PhoneKeyStore, @unchecked Sendable {
    private let backend: any KeychainBackend
    private let privateGroup: String?
    private let alertGroup: String?
    private let lock = NSLock()

    public init(backend: any KeychainBackend, privateGroup: String?, alertGroup: String?) {
        self.backend = backend
        self.privateGroup = privateGroup
        self.alertGroup = alertGroup
    }

    private func put(_ data: Data, _ account: String, _ access: KeyAccess, useAlertGroup: Bool = false) throws {
        try backend.write(data, account: account, access: access, group: useAlertGroup ? alertGroup : privateGroup, dataProtection: true)
    }

    public func identity() throws -> DeviceIdentityKeys {
        try lock.withLock {
            let sigData = try backend.read(account: "identity.sig", group: privateGroup)
            let kxData = try backend.read(account: "identity.kx", group: privateGroup)
            let keys: DeviceIdentityKeys
            switch (sigData, kxData) {
            case let (sig?, kx?):
                keys = try Self.parseIdentity(sig, kx)
            case (nil, nil):
                keys = try createIdentity()
            default:
                // One half present: recreating would silently replace the device identity.
                throw KeyStoreError.corrupt("device identity is half present")
            }
            let idData = Data(keys.deviceID.uuidString.utf8)
            if try backend.read(account: "deviceid", group: privateGroup) != idData {
                try put(idData, "deviceid", .afterFirstUnlock)
            }
            return keys
        }
    }

    /// Add-only creation. Losing the race on `identity.sig` (another creator) loads what that creator stored;
    /// losing it on `identity.kx` means two creators interleaved and is corrupt.
    private func createIdentity() throws -> DeviceIdentityKeys {
        let fresh = DeviceIdentityKeys(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
        guard try backend.add(
            fresh.signing.rawRepresentation, account: "identity.sig", access: .whenUnlocked, group: privateGroup, dataProtection: true)
        else {
            guard let sig = try backend.read(account: "identity.sig", group: privateGroup),
                  let kx = try backend.read(account: "identity.kx", group: privateGroup) else {
                throw KeyStoreError.corrupt("device identity is half present")
            }
            return try Self.parseIdentity(sig, kx)
        }
        guard try backend.add(
            fresh.agreement.rawRepresentation, account: "identity.kx", access: .whenUnlocked, group: privateGroup, dataProtection: true)
        else { throw KeyStoreError.corrupt("device identity was created concurrently") }
        return fresh
    }

    private static func parseIdentity(_ sig: Data, _ kx: Data) throws -> DeviceIdentityKeys {
        do {
            return DeviceIdentityKeys(
                signing: try Curve25519.Signing.PrivateKey(rawRepresentation: sig),
                agreement: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: kx))
        } catch {
            throw KeyStoreError.corrupt("device identity keys do not parse")
        }
    }

    public func hubLink(_ hubID: String) throws -> HubLinkKeys? {
        guard let data = try backend.read(account: "hub.\(hubID)", group: privateGroup) else { return nil }
        do { return try JSONDecoder().decode(HubLinkKeys.self, from: data) } catch {
            throw KeyStoreError.corrupt("hub link does not decode")
        }
    }

    public func saveHubLink(_ keys: HubLinkKeys) throws {
        let sizes = [keys.hubSigningKey, keys.hubAgreementKey] + (keys.metaKey.map { [$0] } ?? [])
            + keys.epochs.flatMap { [$0.dataKey, $0.alertKey] }
        guard sizes.allSatisfy({ $0.count == 32 }) else { throw KeyStoreError.corrupt("a hub link key is not 32 bytes") }
        var trimmed = keys
        trimmed.epochs = Array(keys.epochs.suffix(HubLinkKeys.maxEpochs))
        let alert = AlertMaterial(
            epochs: trimmed.epochs.map { EpochKeys(epoch: $0.epoch, dataKey: Data(), alertKey: $0.alertKey) },
            hubSigningKey: keys.hubSigningKey)
        try lock.withLock {
            try put(try JSONEncoder().encode(trimmed), "hub.\(keys.hubID)", .whenUnlocked)
            try put(keys.hubSigningKey, "hubpub.\(keys.hubID)", .afterFirstUnlock)
            try put(try JSONEncoder().encode(alert), "alert.\(keys.hubID)", .afterFirstUnlock, useAlertGroup: true)
        }
    }

    public func removeHubLink(_ hubID: String) throws {
        try lock.withLock {
            try backend.delete(account: "hub.\(hubID)", group: privateGroup)
            try backend.delete(account: "hubpub.\(hubID)", group: privateGroup)
            try backend.delete(account: "alert.\(hubID)", group: alertGroup)
        }
    }

    public func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey? {
        guard let data = try backend.read(account: "hubpub.\(hubID)", group: privateGroup) else { return nil }
        do { return try Curve25519.Signing.PublicKey(rawRepresentation: data) } catch {
            throw KeyStoreError.corrupt("hub signing key does not parse")
        }
    }

    public func alertMaterial(_ hubID: String) throws -> AlertMaterial? {
        guard let data = try backend.read(account: "alert.\(hubID)", group: alertGroup) else { return nil }
        do { return try JSONDecoder().decode(AlertMaterial.self, from: data) } catch {
            throw KeyStoreError.corrupt("alert material does not decode")
        }
    }

    public func deviceID() throws -> UUID? {
        guard let data = try backend.read(account: "deviceid", group: privateGroup) else { return nil }
        guard let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
            throw KeyStoreError.corrupt("device id does not parse")
        }
        return id
    }
}

/// The Mac hub's identity: `afterFirstUnlock` (D2, the hub answers while the screen is locked), data protection keychain.
public final class KeychainHubKeyStore: HubKeyStore, @unchecked Sendable {
    private let backend: any KeychainBackend
    private let lock = NSLock()

    public init(backend: any KeychainBackend) {
        self.backend = backend
    }

    public func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool) {
        try lock.withLock {
            if let existing = try load(hubID) { return (existing, false) }
            let fresh = HubIdentityKeys(
                signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(),
                wrapKey: SymmetricKey(size: .bits256))
            let items = [
                ("hubid.\(hubID).sig", fresh.signing.rawRepresentation),
                ("hubid.\(hubID).kx", fresh.agreement.rawRepresentation),
                ("hubid.\(hubID).wrap", fresh.wrapKey.withUnsafeBytes { Data($0) })
            ]
            for (index, item) in items.enumerated() {
                let added = try backend.add(item.1, account: item.0, access: .afterFirstUnlock, group: nil, dataProtection: true)
                guard added else {
                    // Another creator got there. Losing the first item means its identity is (becoming) the stored one;
                    // losing a later one means two creators interleaved, which is never mixed silently.
                    if index == 0, let existing = try load(hubID) { return (existing, false) }
                    throw KeyStoreError.corrupt("hub identity was created concurrently")
                }
            }
            return (fresh, true)
        }
    }

    /// nil when no item exists; all three must parse, otherwise `.corrupt`.
    private func load(_ hubID: String) throws -> HubIdentityKeys? {
        let sig = try backend.read(account: "hubid.\(hubID).sig", group: nil)
        let kx = try backend.read(account: "hubid.\(hubID).kx", group: nil)
        let wrap = try backend.read(account: "hubid.\(hubID).wrap", group: nil)
        switch (sig, kx, wrap) {
        case (nil, nil, nil): return nil
        case let (sig?, kx?, wrap?):
            guard wrap.count == 32 else { throw KeyStoreError.corrupt("hub wrap key is not 32 bytes") }
            do {
                return HubIdentityKeys(
                    signing: try Curve25519.Signing.PrivateKey(rawRepresentation: sig),
                    agreement: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: kx),
                    wrapKey: SymmetricKey(data: wrap))
            } catch {
                throw KeyStoreError.corrupt("hub identity keys do not parse")
            }
        default:
            // A partial identity is never replaced silently: the wrap key guards the sealed epoch keys.
            throw KeyStoreError.corrupt("hub identity is partially present")
        }
    }

    public func deleteHubIdentity(hubID: String) throws {
        try lock.withLock {
            for suffix in ["sig", "kx", "wrap"] { try backend.delete(account: "hubid.\(hubID).\(suffix)", group: nil) }
        }
    }
}
