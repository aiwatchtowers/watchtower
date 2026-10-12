import CryptoKit
import Foundation

/// The folder the code viewer of one workbench works in (board #565, spec
/// 2026-10-12-session-worktree-design §6.1): the workbench folder itself
/// (the main root) or a linked git worktree a session's agent works in.
/// Code-viewer state — tabs, recents, buffers, the index — is keyed by it,
/// so each worktree keeps its own set (owner, ask #188) and a buffer made
/// for one root never writes into another (PROJ-03).
package struct CodeRoot: Hashable, Sendable {
    package let workbenchID: Int64
    /// Standardized lexically only (`.`/`..` removed, always a directory
    /// URL, so a trailing slash does not matter), never symlink-resolved. The
    /// identity, the hash and `defaultsKeySuffix` derive from it, so they
    /// depend only on the spelling passed in, not on whether the directory
    /// exists when the root is built: a worktree deleted and recreated keeps
    /// its key. Two spellings of one directory (`/tmp/x` vs `/private/tmp/x`)
    /// are two roots; callers pass the spelling git reports. Filesystem-aware
    /// comparisons ("is this the workbench folder") are `CodeRootPolicy`'s.
    package let folder: URL
    package let isMain: Bool

    /// The workbench folder.
    package init(main workbench: Workbench) {
        workbenchID = workbench.id
        folder = Self.lexicalFolder(workbench.folderURL)
        isMain = true
    }

    /// A linked worktree of the workbench's repository.
    package init(workbenchID: Int64, worktree folder: URL) {
        self.workbenchID = workbenchID
        self.folder = Self.lexicalFolder(folder)
        isMain = false
    }

    /// What a per-workbench UserDefaults key gains for this root: nothing for
    /// the main root (today's keys stay valid), `.wt.<16 hex>` for a worktree
    /// — the first 8 bytes of the SHA-256 of its folder path.
    package var defaultsKeySuffix: String {
        guard !isMain else { return "" }
        let digest = SHA256.hash(data: Data(folder.path.utf8))
        return ".wt." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func lexicalFolder(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
    }
}

package extension Workbench {
    /// The root the code viewer uses when no session puts a worktree on screen.
    var mainCodeRoot: CodeRoot { CodeRoot(main: self) }
}
