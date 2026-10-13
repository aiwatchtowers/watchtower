import Foundation
import Security
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's keys in the real Keychain (`SecItemKeychainBackend`, mobile E2E spec §2.6). An unsigned simulator
/// build has no Keychain entitlement and skips (F24): the attributes are also asserted by the Kit's pure builder
/// test, which always runs. The behaviour of the key store itself is covered over `InMemoryKeychainBackend`.
final class KeychainKeyStoreDeviceTests: XCTestCase {
    /// Its own service, so the test never touches the app's items.
    private let backend = SecItemKeychainBackend(service: "com.aiwatchtowers.watchtower.e2e.device-tests")
    private let accounts = ["identity.sig", "identity.kx", "deviceid"]

    override func tearDown() {
        for account in accounts {
            do {
                try backend.delete(account: account, group: nil)
            } catch {
                // Nothing to clean when the Keychain refused every write (unsigned): not a failure of the test.
                continue
            }
        }
        super.tearDown()
    }

    func testIdentityRoundTripsAndIsNotSynchronizable() throws {
        let store = KeychainPhoneKeyStore(backend: backend, privateGroup: nil, alertGroup: nil)
        let first: DeviceIdentityKeys
        do {
            first = try store.identity()
        } catch KeyStoreError.missingEntitlement {
            throw XCTSkip("no Keychain entitlement in an unsigned build (F24)")
        }

        let again = try store.identity()
        XCTAssertEqual(again.deviceID, first.deviceID, "the identity is created once and read back")
        XCTAssertEqual(try store.deviceID(), first.deviceID)

        let secret = try XCTUnwrap(attributes(account: "identity.sig"))
        XCTAssertEqual(secret[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(secret[kSecAttrSynchronizable as String] as? Bool, true, "never synchronizable")
        let deviceID = try XCTUnwrap(attributes(account: "deviceid"))
        XCTAssertEqual(
            deviceID[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            "F14: the device id reads while locked"
        )
        XCTAssertNotEqual(deviceID[kSecAttrSynchronizable as String] as? Bool, true)
    }

    /// The live store needs the private group from Info.plist (F20).
    func testThePrivateGroupComesFromInfoPlist() throws {
        XCTAssertEqual(try PhoneKeychain.privateGroup(in: ["WTKeychainPrivateGroup": "TEAM.com.example.app"]), "TEAM.com.example.app")
        XCTAssertThrowsError(try PhoneKeychain.privateGroup(in: [:])) { error in
            XCTAssertEqual(error as? PhoneKeychainError, .privateGroupMissing)
        }
        XCTAssertThrowsError(try PhoneKeychain.privateGroup(in: ["WTKeychainPrivateGroup": ""]))
        XCTAssertNotNil(Bundle(for: AppRoot.self).object(forInfoDictionaryKey: PhoneKeychain.privateGroupKey), "the app's Info.plist has it")
    }

    /// The alert material goes to the shared group from Info.plist (spec §2.6), never a hardcoded one.
    func testTheAlertGroupComesFromInfoPlist() throws {
        XCTAssertEqual(try PhoneKeychain.alertGroup(in: ["WTKeychainAlertGroup": "TEAM.com.example.alerts"]), "TEAM.com.example.alerts")
        XCTAssertThrowsError(try PhoneKeychain.alertGroup(in: [:])) { error in
            XCTAssertEqual(error as? PhoneKeychainError, .alertGroupMissing)
        }
        XCTAssertThrowsError(try PhoneKeychain.alertGroup(in: ["WTKeychainAlertGroup": ""]))
        let bundle = Bundle(for: AppRoot.self)
        let alerts = try XCTUnwrap(bundle.object(forInfoDictionaryKey: PhoneKeychain.alertGroupKey) as? String)
        let privateGroup = try XCTUnwrap(bundle.object(forInfoDictionaryKey: PhoneKeychain.privateGroupKey) as? String)
        XCTAssertNotEqual(alerts, privateGroup, "the alert material never shares the private group")
        XCTAssertTrue(alerts.hasSuffix("com.aiwatchtowers.watchtower.mobile.alerts"))
    }

    /// F20: the private group is the app's FIRST (default) keychain group and the alerts group the second; the
    /// extension holds the alerts group only (F21). Read from the source tree: an unsigned build embeds none.
    func testTheKeychainGroupsAreOrderedPrivateFirstAndTheExtensionHoldsOnlyAlerts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try keychainGroups(root.appendingPathComponent("WatchtowerMobile.entitlements"))
        XCTAssertEqual(app, [
            "$(AppIdentifierPrefix)com.aiwatchtowers.watchtower.mobile",
            "$(AppIdentifierPrefix)com.aiwatchtowers.watchtower.mobile.alerts"
        ])
        let service = try keychainGroups(root.appendingPathComponent("NotifyService/NotifyService.entitlements"))
        XCTAssertEqual(service, ["$(AppIdentifierPrefix)com.aiwatchtowers.watchtower.mobile.alerts"])
        let serviceInfo = try plist(root.appendingPathComponent("NotifyService/Info.plist"))
        XCTAssertEqual(serviceInfo[PhoneKeychain.alertGroupKey] as? String, app.last)
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func keychainGroups(_ url: URL) throws -> [String] {
        try XCTUnwrap(plist(url)["keychain-access-groups"] as? [String])
    }

    /// M-1: the #62 device id (its Keychain item and the defaults fallback) is removed after the move to the
    /// key-derived id; "no such item" is not a failure.
    @MainActor
    func testTheLegacyDeviceIDIsRemoved() throws {
        let defaults = try makeDefaults()
        defaults.set("legacy-id", forKey: LegacyDeviceID.defaultsKey)
        var deletes = 0

        LegacyDeviceID.remove(defaults: defaults) {
            deletes += 1
            return errSecItemNotFound
        }

        XCTAssertNil(defaults.string(forKey: LegacyDeviceID.defaultsKey))
        XCTAssertEqual(deletes, 1)
        XCTAssertEqual(LegacyDeviceID.service, "com.aiwatchtowers.watchtower.mobile.device")
        XCTAssertEqual(LegacyDeviceID.account, "device_id")
    }

    private func attributes(account: String) throws -> [String: Any]? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: backend.service,
            kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
            kSecAttrSynchronizable: kSecAttrSynchronizableAny,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitOne
        ] as CFDictionary, &result)
        guard status == errSecSuccess else {
            XCTFail("attributes of \(account) unreadable: \(status)")
            return nil
        }
        return result as? [String: Any]
    }
}
