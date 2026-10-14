import Foundation
import UIKit
import WatchtowerSync

/// What this phone's `device` record says about the phone itself (spec
/// §5.1).
struct DeviceIdentity: Equatable, Sendable {
    /// `UUID.uuidString` of the device's signing key hash (D7, F30), from
    /// `PhoneKeyStore.deviceID()`; nil until the link flow first creates the
    /// device keys.
    var deviceID: String?
    let name: String
    let model: String
    let appVersion: String

    /// nil while the phone has no device keys.
    func linkedDevice(scope: DeviceScope, userRecordName: String) -> LinkedDevice? {
        deviceID.map {
            LinkedDevice(
                deviceID: $0,
                name: name,
                model: model,
                appVersion: appVersion,
                scope: scope,
                userRecordName: userRecordName
            )
        }
    }

    func linkedDevice(for link: LinkRecord) -> LinkedDevice? {
        linkedDevice(scope: link.scope, userRecordName: link.userRecordName)
    }

    /// This phone: the device id from the key store, the device's name (at
    /// most 60 grapheme clusters) and model, the app's marketing version.
    ///
    /// F14: only the non-secret `deviceid` item is read, which works while
    /// the phone is locked; the identity is never created here (a background
    /// launch must not mint one: only the link flow does, in the foreground).
    /// Before the first unlock since a restart even that item is unreadable:
    /// `KeyStoreError.locked` is thrown and the boot waits for the unlock,
    /// never treating "locked" as "no identity" (#62's guarantee).
    @MainActor
    static func current(keys: any PhoneKeyStore) throws -> Self {
        Self(
            deviceID: try keys.deviceID()?.uuidString,
            name: String(UIDevice.current.name.prefix(DevicePayload.maxNameLength)),
            model: UIDevice.current.model,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        )
    }
}
