import Foundation
import WatchtowerCore

/// What the branch header's state is keyed by (board #565, spec §5.3): a
/// workbench's main folder, or one linked worktree of its repository — the
/// `CodeRoot` the page shows, reduced to the parts that name it. The main
/// root carries no folder, so the main entry is found by the workbench id
/// alone and its CLI argv never gains `--folder`.
struct GitRootKey: Hashable, Sendable {
    let workbenchID: Int64
    /// The worktree root (`CodeRoot.folder`'s path); nil = the main folder.
    let worktreeFolder: String?

    init(_ root: CodeRoot) {
        workbenchID = root.workbenchID
        worktreeFolder = root.isMain ? nil : root.folder.path
    }

    /// The workbench's main folder.
    static func mainFolder(_ workbenchID: Int64) -> Self { Self(workbenchID: workbenchID, worktreeFolder: nil) }

    private init(workbenchID: Int64, worktreeFolder: String?) {
        self.workbenchID = workbenchID
        self.worktreeFolder = worktreeFolder
    }
}

extension Dictionary where Key == GitRootKey {
    /// The workbench's main-folder entry.
    subscript(_ workbenchID: Int64) -> Value? {
        get { self[.mainFolder(workbenchID)] }
        set { self[.mainFolder(workbenchID)] = newValue }
    }

    /// The entry of `root` (main or worktree).
    subscript(_ root: CodeRoot) -> Value? {
        get { self[GitRootKey(root)] }
        set { self[GitRootKey(root)] = newValue }
    }
}
