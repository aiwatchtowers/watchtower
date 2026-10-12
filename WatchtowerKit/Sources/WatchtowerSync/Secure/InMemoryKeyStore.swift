import CryptoKit
import Foundation

/// A keychain stand-in that remembers each item's access class and can simulate a locked device. Tests and demo only.
public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (data: Data, access: KeyAccess)] = [:]
    private var locked = false
    private var beforeFirstUnlock = false

    public init() {}

    /// whenUnlocked reads throw `.locked`.
    public var isLocked: Bool {
        get { lock.withLock { locked } }
        set { lock.withLock { locked = newValue } }
    }

    /// Every read throws `.locked`, afterFirstUnlock items included.
    public var isBeforeFirstUnlock: Bool {
        get { lock.withLock { beforeFirstUnlock } }
        set { lock.withLock { beforeFirstUnlock = newValue } }
    }

    private func key(_ account: String, _ group: String?) -> String { "\(group ?? "")|\(account)" }

    public func read(account: String, group: String?) throws -> Data? {
        try lock.withLock {
            if beforeFirstUnlock { throw KeyStoreError.locked }
            // Like the real keychain: an absent item is nil even while locked.
            guard let item = items[key(account, group)] else { return nil }
            if locked, item.access == .whenUnlocked { throw KeyStoreError.locked }
            return item.data
        }
    }

    public func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws {
        try lock.withLock {
            try checkWritable(access)
            items[key(account, group)] = (data, access)
        }
    }

    public func add(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws -> Bool {
        try lock.withLock {
            try checkWritable(access)
            guard items[key(account, group)] == nil else { return false }
            items[key(account, group)] = (data, access)
            return true
        }
    }

    /// Callers hold `lock`.
    private func checkWritable(_ access: KeyAccess) throws {
        if beforeFirstUnlock || (locked && access == .whenUnlocked) { throw KeyStoreError.locked }
    }

    public func delete(account: String, group: String?) throws {
        lock.withLock { items[key(account, group)] = nil }
    }
}

public final class InMemoryPhoneKeyStore: PhoneKeyStore, @unchecked Sendable {
    private let backend = InMemoryKeychainBackend()
    private let store: KeychainPhoneKeyStore

    public init() {
        store = KeychainPhoneKeyStore(backend: backend, privateGroup: nil, alertGroup: nil)
    }

    /// A store whose device identity is `identity` (a fixed test pairing) instead of a fresh one.
    public convenience init(identity: DeviceIdentityKeys) throws {
        self.init()
        _ = try backend.add(
            identity.signing.rawRepresentation, account: "identity.sig", access: .whenUnlocked, group: nil, dataProtection: true)
        _ = try backend.add(
            identity.agreement.rawRepresentation, account: "identity.kx", access: .whenUnlocked, group: nil, dataProtection: true)
        _ = try store.identity()
    }

    public var isLocked: Bool {
        get { backend.isLocked }
        set { backend.isLocked = newValue }
    }

    public var isBeforeFirstUnlock: Bool {
        get { backend.isBeforeFirstUnlock }
        set { backend.isBeforeFirstUnlock = newValue }
    }

    public func identity() throws -> DeviceIdentityKeys { try store.identity() }
    public func hubLink(_ hubID: String) throws -> HubLinkKeys? { try store.hubLink(hubID) }
    public func saveHubLink(_ keys: HubLinkKeys) throws { try store.saveHubLink(keys) }
    public func removeHubLink(_ hubID: String) throws { try store.removeHubLink(hubID) }
    public func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey? { try store.hubSigningKey(hubID) }
    public func alertMaterial(_ hubID: String) throws -> AlertMaterial? { try store.alertMaterial(hubID) }
    public func deviceID() throws -> UUID? { try store.deviceID() }
}

public final class InMemoryHubKeyStore: HubKeyStore, @unchecked Sendable {
    private let store = KeychainHubKeyStore(backend: InMemoryKeychainBackend())

    public init() {}

    public func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool) { try store.hubIdentity(hubID: hubID) }
    public func deleteHubIdentity(hubID: String) throws { try store.deleteHubIdentity(hubID: hubID) }
}
