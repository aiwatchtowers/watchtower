import Foundation
import os
import Security

/// The device id in the Keychain (`kSecClassGenericPassword`, this device
/// only, readable after the first unlock), created on first use.
///
/// The read decides, in order:
/// - an id in the Keychain is the id;
/// - `errSecItemNotFound`: the id kept in `UserDefaults` (an earlier
///   Keychain refused the write), else a new one;
/// - `errSecInteractionNotAllowed` (a push launch before the first unlock):
///   `Unavailable`, locked — the boot waits for protected data
///   (`WatchtowerMobileApp.Boot.waitingForUnlock`) and retries;
/// - any other status: the id kept in `UserDefaults` when there is one
///   (a Keychain that refused the write may refuse the read too), else
///   `Unavailable`, shown by `BootFailureView`.
/// A new id is minted only on a confirmed "no entry": it would make this
/// phone a stranger to its Mac (actions fail `device_not_linked`, the grant
/// is another device's).
enum DeviceIDKeychain {
    /// The Keychain could not say whether a device id is stored.
    struct Unavailable: LocalizedError, Equatable {
        let status: OSStatus

        /// The Keychain is locked until the first unlock after a restart.
        var isLocked: Bool { status == errSecInteractionNotAllowed }

        var errorDescription: String? {
            isLocked
                ? "Unlock this iPhone to start Watchtower."
                : "The Keychain could not read this iPhone's Watchtower id (status \(status))."
        }
    }

    /// One Keychain read: the stored id, no entry, or another status.
    enum ReadResult: Equatable {
        case found(String)
        case notFound
        case failed(OSStatus)
    }

    /// The Keychain calls, injectable so tests never touch the real one.
    struct Access {
        var read: () -> ReadResult
        /// Stores a new id; returns the `SecItemAdd` status.
        var add: (String) -> OSStatus
    }

    fileprivate static let service = "com.aiwatchtowers.watchtower.mobile.device"
    fileprivate static let account = "device_id"
    static let fallbackKey = "device.id"
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "DeviceIDKeychain")

    /// The device id, by the order above. A Keychain that refuses the write
    /// of a new id keeps it in `fallback` (lost on reinstall) instead.
    static func deviceID(fallback: UserDefaults, access: Access = .live) throws -> String {
        switch access.read() {
        case let .found(stored):
            return stored
        case let .failed(status):
            let unavailable = Unavailable(status: status)
            if !unavailable.isLocked, let kept = fallback.string(forKey: fallbackKey) {
                logger.warning("keychain read failed (\(status, privacy: .public)); using the id kept in defaults")
                return kept
            }
            logger.error("keychain read failed (\(status, privacy: .public)); not minting a new device id")
            throw unavailable
        case .notFound:
            break
        }
        if let kept = fallback.string(forKey: fallbackKey) { return kept }
        let created = UUID().uuidString
        let status = access.add(created)
        if status != errSecSuccess {
            logger.error("keychain refused the device id (\(status, privacy: .public)); keeping it in defaults")
            fallback.set(created, forKey: fallbackKey)
        }
        return created
    }
}

extension DeviceIDKeychain.Access {
    /// The real Keychain.
    static let live = Self(
        read: {
            var item: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: DeviceIDKeychain.service,
                kSecAttrAccount: DeviceIDKeychain.account,
                kSecReturnData: true,
                kSecMatchLimit: kSecMatchLimitOne
            ] as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                // An entry that is not a UTF-8 string cannot be this app's
                // id; it is not "no entry" either.
                guard let data = item as? Data, let id = String(bytes: data, encoding: .utf8) else {
                    return .failed(errSecDecode)
                }
                return .found(id)
            case errSecItemNotFound:
                return .notFound
            default:
                return .failed(status)
            }
        },
        add: { id in
            SecItemAdd([
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: DeviceIDKeychain.service,
                kSecAttrAccount: DeviceIDKeychain.account,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData: Data(id.utf8)
            ] as CFDictionary, nil)
        }
    )
}
