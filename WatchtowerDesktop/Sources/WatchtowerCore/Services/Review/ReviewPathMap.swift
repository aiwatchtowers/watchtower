import Foundation

/// Between a review round's paths, relative to the repository top, and a
/// code root's, relative to the workbench folder (board #960, spec §2
/// "Paths"): the folder's place inside the repository is the prefix.
package struct ReviewPathMap: Equatable, Sendable {
    /// "" at the top of the repository, else `apps/web/` (one trailing slash).
    private let prefix: String

    /// `repoPrefix`: `git rev-parse --show-prefix` of the workbench folder;
    /// leading and trailing slashes are ignored.
    package init(repoPrefix: String) {
        let trimmed = repoPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        prefix = trimmed.isEmpty ? "" : trimmed + "/"
    }

    /// nil for a path outside the folder: the code index has no such file.
    package func toRoot(_ repoPath: String) -> String? {
        guard repoPath.hasPrefix(prefix) else { return nil }
        let relative = String(repoPath.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    package func toRepo(_ rootPath: String) -> String {
        prefix + rootPath
    }
}
