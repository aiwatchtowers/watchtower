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
                do {
                    keys = DeviceIdentityKeys(
                        signing: try Curve25519.Signing.PrivateKey(rawRepresentation: sig),
                        agreement: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: kx))
                } catch {
                    throw KeyStoreError.corrupt("device identity keys do not parse")
                }
            case (nil, nil):
                keys = DeviceIdentityKeys(signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey())
                try put(keys.signing.rawRepresentation, "identity.sig", .whenUnlocked)
                try put(keys.agreement.rawRepresentation, "identity.kx", .whenUnlocked)
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

    public func hubLink(_ hubID: String) throws -> HubLinkKeys? {
        guard let data = try backend.read(account: "hub.\(hubID)", group: privateGroup) else { return nil }
        do { return try JSONDecoder().decode(HubLinkKeys.self, from: data) } catch {
            throw KeyStoreError.corrupt("hub link does not decode")
        }
    }

    public func saveHubLink(_ keys: HubLinkKeys) throws {
        guard keys.hubSigningKey.count == 32 else { throw KeyStoreError.corrupt("hub signing key is not 32 bytes") }
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
            let sig = try backend.read(account: "hubid.\(hubID).sig", group: nil)
            let kx = try backend.read(account: "hubid.\(hubID).kx", group: nil)
            let wrap = try backend.read(account: "hubid.\(hubID).wrap", group: nil)
            switch (sig, kx, wrap) {
            case let (sig?, kx?, wrap?):
                do {
                    let keys = HubIdentityKeys(
                        signing: try Curve25519.Signing.PrivateKey(rawRepresentation: sig),
                        agreement: try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: kx),
                        wrapKey: SymmetricKey(data: wrap))
                    guard wrap.count == 32 else { throw KeyStoreError.corrupt("hub wrap key is not 32 bytes") }
                    return (keys, false)
                } catch let error as KeyStoreError {
                    throw error
                } catch {
                    throw KeyStoreError.corrupt("hub identity keys do not parse")
                }
            case (nil, nil, nil):
                let keys = HubIdentityKeys(
                    signing: Curve25519.Signing.PrivateKey(), agreement: Curve25519.KeyAgreement.PrivateKey(),
                    wrapKey: SymmetricKey(size: .bits256))
                try put(keys.signing.rawRepresentation, "hubid.\(hubID).sig")
                try put(keys.agreement.rawRepresentation, "hubid.\(hubID).kx")
                try put(keys.wrapKey.withUnsafeBytes { Data($0) }, "hubid.\(hubID).wrap")
                return (keys, true)
            default:
                // A partial identity is never replaced silently: the wrap key guards the sealed epoch keys.
                throw KeyStoreError.corrupt("hub identity is partially present")
            }
        }
    }

    private func put(_ data: Data, _ account: String) throws {
        try backend.write(data, account: account, access: .afterFirstUnlock, group: nil, dataProtection: true)
    }

    public func deleteHubIdentity(hubID: String) throws {
        try lock.withLock {
            for suffix in ["sig", "kx", "wrap"] { try backend.delete(account: "hubid.\(hubID).\(suffix)", group: nil) }
        }
    }
}
