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
    /// Standardized; for a worktree also symlink-resolved (realpath(3)) when
    /// it exists, so one directory reached by two spellings is one root.
    package let folder: URL
    package let isMain: Bool

    /// The workbench folder.
    package init(main workbench: Workbench) {
        workbenchID = workbench.id
        folder = workbench.folderURL.standardizedFileURL
        isMain = true
    }

    /// A linked worktree of the workbench's repository.
    package init(workbenchID: Int64, worktree folder: URL) {
        self.workbenchID = workbenchID
        self.folder = Self.canonical(folder)
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

    private static func canonical(_ url: URL) -> URL {
        let standard = url.standardizedFileURL
        guard let resolved = realpath(standard.path, nil) else { return standard }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}

package extension Workbench {
    /// The root the code viewer uses when no session puts a worktree on screen.
    var mainCodeRoot: CodeRoot { CodeRoot(main: self) }
}
