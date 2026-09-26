import Foundation

/// Reliable resource bundle accessor for both SPM development and .app distribution.
///
/// SPM's auto-generated `Bundle.module` uses `Bundle.main.bundleURL` which points to
/// the `.app` root — but macOS .app bundles store resources in `Contents/Resources/`.
/// This accessor searches multiple standard locations to work in all contexts.
enum AppBundle {
    static let resources: Bundle = {
        let bundleName = "WatchtowerDesktop_WatchtowerDesktop"

        // 1. macOS .app bundle: Contents/Resources/ (standard distribution path)
        if let resourceURL = Bundle.main.resourceURL {
            let path = resourceURL.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: path) {
                return bundle
            }
        }

        // 2. .app root / SPM executable directory (bundleURL)
        let mainPath = Bundle.main.bundleURL.appendingPathComponent(bundleName + ".bundle")
        if let bundle = Bundle(url: mainPath) {
            return bundle
        }

        // 3. Next to the executable (Contents/MacOS/ or flat executable)
        if let execURL = Bundle.main.executableURL?.deletingLastPathComponent() {
            let path = execURL.appendingPathComponent(bundleName + ".bundle")
            if let bundle = Bundle(url: path) {
                return bundle
            }
        }

        // 4. Fallback: SPM's generated Bundle.module (works during swift run / swift test)
        return Bundle.module
    }()
}
