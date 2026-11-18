import CryptoKit
import Foundation

/// The folder the code viewer of one workbench works in (board #565, spec
/// 2026-10-12-session-worktree-design §6.1): the workbench folder itself
/// (the main root) or a linked git worktree a session's agent works in.
/// Code-viewer state — tabs, recents, buffers, the index — is keyed by it,
/// so each worktree keeps its own set (owner, ask #188) and a buffer made
/// for one root never writes into another (PROJ-03). A workbench of several
/// folders (#2003) has one main root per folder; `folderID` tells a folder
/// other than home apart (nil = the home folder, so today's roots and keys
/// are unchanged).
package struct CodeRoot: Hashable, Sendable {
    package let workbenchID: Int64
    /// The workbench folder this root is (or is a worktree of); nil = the
    /// home folder.
    package let folderID: Int64?
    /// Normalized lexically only (`.`/`..`, duplicate and trailing slashes
    /// collapsed, always a directory URL), never touching the filesystem: no
    /// symlink resolution and no `/private` stripping, so the main root's
    /// folder is the stored workbench folder byte for byte. The
    /// identity, the hash and `defaultsKeySuffix` derive from it, so they
    /// depend only on the spelling passed in, not on whether the directory
    /// exists when the root is built: a worktree deleted and recreated keeps
    /// its key. Two spellings of one directory (`/tmp/x` vs `/private/tmp/x`)
    /// are two roots; callers pass the spelling git reports. Filesystem-aware
    /// comparisons ("is this the workbench folder") are `CodeRootPolicy`'s.
    package let folder: URL
    package let isMain: Bool

    /// The workbench folder (its home folder).
    package init(main workbench: Workbench) {
        workbenchID = workbench.id
        folderID = nil
        folder = Self.lexicalFolder(workbench.folderURL)
        isMain = true
    }

    /// A folder of the workbench: the home folder's root equals
    /// `init(main:)`'s (no folder id), any other folder's carries its id.
    package init(folder: WorkbenchFolder, homeFolderID: Int64?) {
        workbenchID = folder.workbenchID
        folderID = folder.id == homeFolderID ? nil : folder.id
        self.folder = Self.lexicalFolder(folder.url)
        isMain = true
    }

    /// A linked worktree of a workbench folder's repository (`folderID` nil:
    /// the home folder's).
    package init(workbenchID: Int64, worktree folder: URL, folderID: Int64? = nil) {
        self.workbenchID = workbenchID
        self.folderID = folderID
        self.folder = Self.lexicalFolder(folder)
        isMain = false
    }

    /// What a per-workbench UserDefaults key gains for this root: nothing for
    /// the home folder's main root (today's keys stay valid), `.f<id>` for
    /// another folder, then `.wt.<16 hex>` for a worktree — the first 8
    /// bytes of the SHA-256 of its folder path.
    package var defaultsKeySuffix: String {
        let folderPart = folderID.map { ".f\($0)" } ?? ""
        guard !isMain else { return folderPart }
        let digest = SHA256.hash(data: Data(folder.path.utf8))
        return folderPart + ".wt." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The worktree's folder name, as the FILES header and the
    /// removed-worktree banner show it. For the main root it is the
    /// workbench folder's name, which neither shows.
    package var worktreeFolderName: String {
        folder.lastPathComponent
    }

    /// The FILES header: `FILES`, or `FILES — ⑂ mobile-a` in a worktree.
    package var filesCaption: String {
        isMain ? "FILES" : "FILES — ⑂ \(worktreeFolderName)"
    }

    /// The banner over the Files pane once this worktree is gone (spec §7).
    package func removedBannerText(unsavedFiles count: Int) -> String {
        let files = count == 1 ? "1 file" : "\(count) files"
        return "The worktree \(worktreeFolderName) was removed — \(files) had unsaved edits"
    }

    /// Pure path arithmetic. `standardizedFileURL` is not used: it strips a
    /// leading `/private` when the shorter spelling exists on disk.
    private static func lexicalFolder(_ url: URL) -> URL {
        var parts: [Substring] = []
        for part in url.absoluteURL.path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"), isDirectory: true)
    }
}

package extension Workbench {
    /// The root the code viewer uses when no session puts a worktree on screen.
    var mainCodeRoot: CodeRoot { CodeRoot(main: self) }
}
