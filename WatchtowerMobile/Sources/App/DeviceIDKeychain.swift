import Foundation
import os
import Security

/// The device id in the Keychain (`kSecClassGenericPassword`, this device
/// only), created on first use.
enum DeviceIDKeychain {
    private static let service = "com.aiwatchtowers.watchtower.mobile.device"
    private static let account = "device_id"
    private static let fallbackKey = "device.id"
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "DeviceIDKeychain")

    /// The stored id, or a new one saved now. A Keychain that refuses the
    /// write keeps the id in `fallback` (lost on reinstall) instead.
    static func deviceID(fallback: UserDefaults) -> String {
        if let stored = read() { return stored }
        if let kept = fallback.string(forKey: fallbackKey) { return kept }
        let created = UUID().uuidString
        let status = SecItemAdd([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(created.utf8)
        ] as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("keychain refused the device id (\(status, privacy: .public)); keeping it in defaults")
            fallback.set(created, forKey: fallbackKey)
        }
        return created
    }

    private static func read() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
