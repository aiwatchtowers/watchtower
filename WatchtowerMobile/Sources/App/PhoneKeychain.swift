import Foundation
import os
import Security
import WatchtowerSync

/// Why the phone's Keychain store could not be set up.
enum PhoneKeychainError: LocalizedError, Equatable {
    /// The build's Info.plist has no `WTKeychainPrivateGroup` (or an empty one).
    case privateGroupMissing
    /// The build's Info.plist has no `WTKeychainAlertGroup` (or an empty one).
    case alertGroupMissing

    var errorDescription: String? {
        switch self {
        case .privateGroupMissing, .alertGroupMissing:
            "This build of Watchtower has no Keychain group. Reinstall Watchtower."
        }
    }
}

/// The phone's E2E keys in the Keychain (mobile E2E spec §2.6): secrets `WhenUnlockedThisDeviceOnly`, the
/// device id and the hub's public signing key `AfterFirstUnlockThisDeviceOnly`, never synchronizable
/// (`SecItemKeychainBackend`). Every item goes to the app's private access group explicitly (F20): the group
/// comes from Info.plist's `WTKeychainPrivateGroup` (`$(AppIdentifierPrefix)…`, expanded at build time), never a
/// hardcoded team prefix; it is the first entry of the entitlements' `keychain-access-groups`. The alert material
/// (`K_alert`, the hub's public signing key) goes to the shared alerts group from `WTKeychainAlertGroup`, the
/// second entry, which the NotifyService extension reads (spec §2.6, F21). The app reads it through one
/// `CachingPhoneKeyStore`: no Keychain query per replica row, nothing served from memory once the phone locks.
enum PhoneKeychain {
    static let privateGroupKey = "WTKeychainPrivateGroup"
    static let alertGroupKey = "WTKeychainAlertGroup"

    static func store(bundle: Bundle = .main) throws -> CachingPhoneKeyStore {
        let info = bundle.infoDictionary ?? [:]
        return CachingPhoneKeyStore(wrapping: KeychainPhoneKeyStore(
            backend: SecItemKeychainBackend(),
            privateGroup: try privateGroup(in: info),
            alertGroup: try alertGroup(in: info)
        ))
    }

    static func privateGroup(in info: [String: Any]) throws -> String {
        guard let group = info[privateGroupKey] as? String, !group.isEmpty else {
            throw PhoneKeychainError.privateGroupMissing
        }
        return group
    }

    static func alertGroup(in info: [String: Any]) throws -> String {
        guard let group = info[alertGroupKey] as? String, !group.isEmpty else {
            throw PhoneKeychainError.alertGroupMissing
        }
        return group
    }
}

/// Main's #62 device id (a random UUID in the Keychain, with a `UserDefaults` fallback), retired by the
/// key-derived id (D7, F30). Removed at launch; idempotent, and "no such item" is the usual case.
enum LegacyDeviceID {
    static let service = "com.aiwatchtowers.watchtower.mobile.device"
    static let account = "device_id"
    static let defaultsKey = "device.id"
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LegacyDeviceID")

    /// `deleteKeychainItem` returns the `SecItemDelete` status; tests pass a stand-in.
    static func remove(defaults: UserDefaults, deleteKeychainItem: () -> OSStatus = deleteLiveItem) {
        defaults.removeObject(forKey: defaultsKey)
        let status = deleteKeychainItem()
        if status != errSecSuccess, status != errSecItemNotFound {
            // Retried at the next launch; the item holds no key, only the retired id.
            logger.warning("legacy device id not removed (\(status, privacy: .public))")
        }
    }

    private static func deleteLiveItem() -> OSStatus {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ] as CFDictionary)
    }
}
