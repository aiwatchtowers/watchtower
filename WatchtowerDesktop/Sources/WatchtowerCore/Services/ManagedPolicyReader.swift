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
    package static func readForced(domain: String = Constants.bundleID) -> [String: Any] {
        let app = domain as CFString
        CFPreferencesAppSynchronize(app)
        var out: [String: Any] = [:]
        for key in ManagedPolicy.Key.allCases {
            let k = key.rawValue as CFString
            guard CFPreferencesAppValueIsForced(k, app) else { continue }
            out[key.rawValue] = CFPreferencesCopyAppValue(k, app) ?? NSNull()
        }
        return out
    }
}
