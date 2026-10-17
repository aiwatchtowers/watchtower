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
        let bare = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        let isRelease = parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }
        let ref = isRelease ? "v" + bare : "main"
        // A fixed https string with a digits-and-dots or "main" ref always parses.
        // swiftlint:disable:next force_unwrapping
        return URL(string: "https://github.com/aiwatchtowers/watchtower/blob/\(ref)/docs/guide/")!
    }

    /// `<baseURL><path>` with `#<anchor>` when the anchor is non-empty.
    package static func url(path: String, anchor: String?) -> URL {
        var string = baseURL.absoluteString + path
        if let anchor, !anchor.isEmpty { string += "#" + anchor }
        return URL(string: string) ?? readme
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
