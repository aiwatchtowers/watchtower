import Foundation

/// Links to the GitHub repository and its releases: the About panel and the
/// user guide. The same in every build flavor (owner ruling, ask #694).
package enum ReleaseLinks {
    // A fixed https string always parses.
    package static let repository = URL(string: "https://github.com/aiwatchtowers/watchtower")!

    /// `v<X.Y.Z>` for a clean `X.Y.Z` version (a leading `v` allowed); nil
    /// for anything else ("dev", "0.19.0-12-gabc-dirty"), whose tag may not
    /// exist or may predate what links to it.
    package static func releaseTag(version: String) -> String? {
        let bare = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        let isRelease = parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }
        return isRelease ? "v" + bare : nil
    }

    /// The release page of a clean version, else the releases list.
    package static func notes(version: String) -> URL {
        let path = releaseTag(version: version).map { "releases/tag/" + $0 } ?? "releases"
        return repository.appendingPathComponent(path)
    }
}
