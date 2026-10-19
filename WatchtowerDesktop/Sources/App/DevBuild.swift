import Foundation

/// Whether this is a `make app-dev` bundle: `build-app.sh --dev` stamps
/// `WTDevBuild` into Info.plist, release builds never carry it. Gates the
/// developer-only Design Gallery window and its Help menu item.
enum DevBuild {
    static func isEnabled(info: [String: Any]?) -> Bool {
        info?["WTDevBuild"] as? Bool ?? false
    }

    static var isEnabled: Bool { isEnabled(info: Bundle.main.infoDictionary) }
}
