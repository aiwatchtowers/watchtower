import Foundation

/// Links into the user guide on GitHub. Mirrors Go `guide.BaseURL`.
package enum GuideLinks {
    /// The guide for this build: its release tag, or main for a dev build
    /// (no Info.plist version when run unbundled).
    package static let baseURL = baseURL(
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")

    package static let readme = baseURL.appendingPathComponent("README.md")

    /// `blob/v<X.Y.Z>/docs/guide/` for a clean `X.Y.Z` version (a leading
    /// `v` allowed); `blob/main/docs/guide/` for anything else ("dev",
    /// "0.19.0-12-gabc-dirty"), whose tag may not exist or may predate the page.
    package static func baseURL(version: String) -> URL {
        let ref = ReleaseLinks.releaseTag(version: version) ?? "main"
        return ReleaseLinks.repository.appendingPathComponent("blob/\(ref)/docs/guide/")
    }

    /// `<baseURL><path>` with `#<anchor>` when the anchor is non-empty.
    package static func url(path: String, anchor: String?) -> URL {
        var string = baseURL.absoluteString + path
        if let anchor, !anchor.isEmpty { string += "#" + anchor }
        return URL(string: string) ?? readme
    }
}
