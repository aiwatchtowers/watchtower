import Foundation
import Security

/// kSecClassGenericPassword under one service. `kSecAttrSynchronizable` is never set, the accessibility is always a
/// `ThisDeviceOnly` class, and the data protection keychain is requested where asked (always on macOS).
public struct SecItemKeychainBackend: KeychainBackend {
    public let service: String

    public init(service: String = "com.aiwatchtowers.watchtower.e2e") {
        self.service = service
    }

    /// The pure attribute builder `write` uses, so the attributes are unit-testable without a signed Keychain.
    func addAttributes(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) -> [String: Any] {
        var attributes = query(account: account, group: group, dataProtection: dataProtection)
        attributes[kSecValueData as String] = data
        switch access {
        case .whenUnlocked: attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlock: attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return attributes
    }

    private func query(account: String, group: String?, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let group { query[kSecAttrAccessGroup as String] = group }
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    static func error(for status: OSStatus) -> KeyStoreError {
        switch status {
        case errSecInteractionNotAllowed: return .locked
        case errSecMissingEntitlement: return .missingEntitlement
        default: return .unexpected(status)
        }
    }

    public func read(account: String, group: String?) throws -> Data? {
        var q = query(account: account, group: group, dataProtection: true)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeyStoreError.corrupt("keychain item \(account) is not data") }
            return data
        case errSecItemNotFound: return nil
        default: throw Self.error(for: status)
        }
    }

    public func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws {
        // Delete first so the accessibility class is always the one asked for (SecItemUpdate would keep the old one).
        let deleted = SecItemDelete(query(account: account, group: group, dataProtection: dataProtection) as CFDictionary)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Self.error(for: deleted) }
        let attributes = addAttributes(data, account: account, access: access, group: group, dataProtection: dataProtection)
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw Self.error(for: added) }
    }

    public func delete(account: String, group: String?) throws {
        let status = SecItemDelete(query(account: account, group: group, dataProtection: true) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(for: status) }
    }
}
