import CoreFoundation
import Foundation

/// Reads the forced (managed) values of the app's preference domain — what a
/// configuration profile delivers. A value written with `defaults write` is
/// not forced and is left out (POLICY-01). Go's `internal/policy` reads the
/// same domain through the same API.
package enum ManagedPolicyReader {
    /// The forced values of every `ManagedPolicy.Key`. A key that is forced
    /// but whose value cannot be copied reads as `NSNull`, a wrong type for
    /// `ManagedPolicy.normalize` (fail closed, as Go's `unsupported{}`).
    /// `isForced` is a seam for the reader's tests (a forced value needs an
    /// installed profile); production asks CoreFoundation.
    package static func readForced(
        domain: String = Constants.bundleID,
        isForced: (_ key: String, _ domain: String) -> Bool = systemIsForced
    ) -> [String: Any] {
        let app = domain as CFString
        CFPreferencesAppSynchronize(app)
        var out: [String: Any] = [:]
        for key in ManagedPolicy.Key.allCases where isForced(key.rawValue, domain) {
            out[key.rawValue] = CFPreferencesCopyAppValue(key.rawValue as CFString, app) ?? NSNull()
        }
        return out
    }

    package static func systemIsForced(_ key: String, _ domain: String) -> Bool {
        CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
    }

    /// The reader a running app uses; empty under XCTest, so no test ever
    /// reads this Mac's managed preferences by accident.
    package static func appRead() -> [String: Any] {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil {
            return [:]
        }
        return readForced()
    }
}
