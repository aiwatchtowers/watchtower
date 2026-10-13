import Foundation
import WatchtowerSync

/// Why the phone's Keychain store could not be set up.
enum PhoneKeychainError: LocalizedError, Equatable {
    /// The build's Info.plist has no `WTKeychainPrivateGroup` (or an empty one).
    case privateGroupMissing

    var errorDescription: String? {
        switch self {
        case .privateGroupMissing:
            "This build of Watchtower has no Keychain group. Reinstall Watchtower."
        }
    }
}

/// The phone's E2E keys in the Keychain (mobile E2E spec §2.6): secrets `WhenUnlockedThisDeviceOnly`, the
/// device id and the hub's public signing key `AfterFirstUnlockThisDeviceOnly`, never synchronizable
/// (`SecItemKeychainBackend`). Every item goes to the app's private access group explicitly (F20): the group
/// comes from Info.plist's `WTKeychainPrivateGroup` (`$(AppIdentifierPrefix)…`, expanded at build time), never a
/// hardcoded team prefix; it is the first entry of the entitlements' `keychain-access-groups`. The alerts group
/// is Task 18's: until then the alert material lands in the private group too.
enum PhoneKeychain {
    static let privateGroupKey = "WTKeychainPrivateGroup"

    static func store(bundle: Bundle = .main) throws -> KeychainPhoneKeyStore {
        KeychainPhoneKeyStore(
            backend: SecItemKeychainBackend(),
            privateGroup: try privateGroup(in: bundle.infoDictionary ?? [:]),
            alertGroup: nil
        )
    }

    static func privateGroup(in info: [String: Any]) throws -> String {
        guard let group = info[privateGroupKey] as? String, !group.isEmpty else {
            throw PhoneKeychainError.privateGroupMissing
        }
        return group
    }
}
