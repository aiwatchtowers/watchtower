import Foundation

/// Links to the GitHub repository and its releases, for the About panel.
/// The same in every build flavor (owner ruling, ask #694).
package enum ReleaseLinks {
    // A fixed https string always parses.
    package static let repository = URL(string: "https://github.com/aiwatchtowers/watchtower")!

    /// `releases/tag/v<X.Y.Z>` for a clean `X.Y.Z` version (a leading `v`
    /// allowed); the releases list for anything else ("dev",
    /// "0.19.0-12-gabc-dirty"), whose tag may not exist.
    package static func notes(version: String) -> URL {
        let bare = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        let isRelease = parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
        let path = isRelease ? "releases/tag/v" + bare : "releases"
        return repository.appendingPathComponent(path)
    }
}
