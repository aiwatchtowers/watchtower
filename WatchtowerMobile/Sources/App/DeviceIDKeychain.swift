import Foundation
import os
import Security

/// The device id in the Keychain (`kSecClassGenericPassword`, this device
/// only, readable after the first unlock), created on first use.
///
/// Only a confirmed "no entry" (`errSecItemNotFound`) mints a new id. Any
/// other read status — `errSecInteractionNotAllowed` when a push launches
/// the app before the first unlock, or anything unexpected — throws
/// `DeviceIDKeychain.Unavailable` instead: a new id would make this phone a
/// stranger to its Mac (actions fail `device_not_linked`, the grant is
/// another device's). The boot then waits for protected data and retries
/// (`WatchtowerMobileApp.Boot.waitingForUnlock`).
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

    /// The stored id; on a confirmed "no entry", the id kept in `fallback`
    /// (an earlier Keychain refused the write), else a new one saved now. A
    /// Keychain that refuses the write keeps the id in `fallback` (lost on
    /// reinstall) instead. Throws `Unavailable` when the read neither found
    /// an id nor confirmed there is none.
    static func deviceID(fallback: UserDefaults, access: Access = .live) throws -> String {
        switch access.read() {
        case let .found(stored):
            return stored
        case let .failed(status):
            logger.error("keychain read failed (\(status, privacy: .public)); not minting a new device id")
            throw Unavailable(status: status)
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
