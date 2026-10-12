import Foundation
import UIKit
import WatchtowerSync

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
    /// grapheme clusters) and model, the app's marketing version. Throws
    /// `DeviceIDKeychain.Unavailable` while the Keychain cannot be read
    /// (before the first unlock): never a new id in place of the stored one.
    @MainActor
    static func current(defaults: UserDefaults = .standard) throws -> Self {
        Self(
            deviceID: try DeviceIDKeychain.deviceID(fallback: defaults),
            name: String(UIDevice.current.name.prefix(DevicePayload.maxNameLength)),
            model: UIDevice.current.model,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        )
    }
}
