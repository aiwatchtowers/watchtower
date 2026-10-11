import Foundation
import os
import Security
import UIKit
import WatchtowerSync

/// The Mac this phone is linked to (mobile POC spec §2.3): the hub, the
/// database scope it syncs through, and the share URLs kept from the scan.
struct LinkRecord: Codable, Equatable, Sendable {
    let hubID: String
    let macName: String
    let scope: DeviceScope
    /// The Mac user's `userRecordID.recordName` (the code's `owner_user`):
    /// in `shared` scope, the owner of every shared zone.
    let ownerName: String
    /// This phone's iCloud user when it linked. Another account signing in
    /// ends the link (spec §9).
    let userRecordName: String
    /// The single-use code the link was made with.
    let nonce: String
    /// The two `CKShare.url`s of a `shared` link (nil in `private` scope):
    /// kept so the shares can be accepted again (spec §2.3 fallback F2).
    let dataShareURL: String?
    let relayShareURL: String?

    /// The database the phone's transport syncs for this link.
    var databaseScope: CloudDatabaseScope {
        scope == .shared ? .shared(ownerName: ownerName) : .private
    }
}

/// A link written to the Mac and not answered yet (spec §2.3 step 5). Kept
/// across a kill, so a relaunch resumes the wait for what is left of it.
struct PendingLink: Codable, Equatable, Sendable {
    let link: LinkRecord
    /// The end of the 60 s grant wait, on the phone's clock.
    let deadline: Date
    /// This phone's grant as the replica held it just before the device
    /// record was written: an earlier answer (a refusal of another code) is
    /// not this scan's.
    let baseline: DeviceGrant?
}

/// The phone's link, persisted in `UserDefaults`: the one record the link
/// flow writes and the app boots from (which database to sync, which
/// device to be).
final class LinkStore {
    private let defaults: UserDefaults
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "LinkStore")

    private enum Keys {
        static let link = "link.record"
        static let pending = "link.pending"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var link: LinkRecord? {
        get { read(LinkRecord.self, key: Keys.link) }
        set { write(newValue, key: Keys.link) }
    }

    var pending: PendingLink? {
        get { read(PendingLink.self, key: Keys.pending) }
        set { write(newValue, key: Keys.pending) }
    }

    /// The database the app syncs at boot: the link's, else a pending
    /// link's, else the phone's own private database.
    var bootScope: CloudDatabaseScope {
        link?.databaseScope ?? pending?.link.databaseScope ?? .private
    }

    /// Plain JSON (local state, not wire format: RelayCoder's snake-case
    /// keys would not round-trip `hubID`). An unreadable value reads as
    /// absent and is logged: the phone then shows Welcome rather than run a
    /// link it cannot read.
    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Self.logger.error("unreadable \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T?, key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            Self.logger.error("could not save \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// What this phone's `device` record says about the phone itself (spec
/// §5.1).
struct DeviceIdentity: Equatable, Sendable {
    /// A UUID kept in the Keychain, so it survives a reinstall.
    let deviceID: String
    let name: String
    let model: String
    let appVersion: String

    func linkedDevice(scope: DeviceScope, userRecordName: String) -> LinkedDevice {
        LinkedDevice(
            deviceID: deviceID,
            name: name,
            model: model,
            appVersion: appVersion,
            scope: scope,
            userRecordName: userRecordName
        )
    }

    func linkedDevice(for link: LinkRecord) -> LinkedDevice {
        linkedDevice(scope: link.scope, userRecordName: link.userRecordName)
    }

    /// This phone: the Keychain device id, the device's name (at most 60
    /// grapheme clusters) and model, the app's marketing version.
    @MainActor
    static func current(defaults: UserDefaults = .standard) -> Self {
        Self(
            deviceID: DeviceIDKeychain.deviceID(fallback: defaults),
            name: String(UIDevice.current.name.prefix(DevicePayload.maxNameLength)),
            model: UIDevice.current.model,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        )
    }
}

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
