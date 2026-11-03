import Foundation
import Security
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest

/// The relay identity in the real Keychain (`SecItemKeychainBackend`). An unsigned simulator build has no Keychain
/// entitlement and skips (F24); the behaviour of `KeychainRelayIdentity` is covered over a recording backend in the Kit.
final class RelayKeychainDeviceTests: XCTestCase {
    /// Its own service, so the test never touches the app's items.
    private let backend = SecItemKeychainBackend(service: "com.aiwatchtowers.watchtower.relay.device-tests")
    private let accounts = ["relay.auth", "relay.attestkey"]

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

    func testRealKeychainRoundTrip() throws {
        let identity = KeychainRelayIdentity(backend: backend, group: nil)
        let created: any RelaySigner
        do {
            created = try identity.signer()
        } catch KeyStoreError.missingEntitlement {
            throw XCTSkip("no Keychain entitlement in an unsigned build (F24)")
        }

        let reread = try XCTUnwrap(KeychainRelayIdentity(backend: backend, group: nil).existingSigner())
        XCTAssertEqual(reread.publicKey, created.publicKey, "created once and read back")
        XCTAssertEqual(try identity.signer().publicKey, created.publicKey)

        identity.setKeyID("attest-key-id")
        XCTAssertEqual(identity.keyID(), "attest-key-id")

        for account in accounts {
            let item = try XCTUnwrap(attributes(account: account))
            XCTAssertEqual(
                item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String, account)
            XCTAssertNotEqual(item[kSecAttrSynchronizable as String] as? Bool, true, "\(account) is never synchronizable")
        }

        identity.setKeyID(nil)
        XCTAssertNil(identity.keyID(), "nil deletes the key id")
        try backend.delete(account: "relay.auth", group: nil)
        XCTAssertNil(try identity.existingSigner(), "deleted")
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
