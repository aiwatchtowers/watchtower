import Foundation
import WatchtowerCore

/// Which code roots and buffers a branch switch of `root` covers (board
/// #565). A root is covered when it is the switched one, or a workbench's
/// main root overlapping the work tree (inside it, or holding it); a
/// buffer when its root is covered, its file is the switched root's or in
/// the work tree, and it is not in another worktree (a known one, or any
/// `.claude/worktrees/<name>` below the work tree).
@MainActor
struct BranchSwitchScope {
    let root: CodeRoot
    private let tree: String
    private let otherWorktrees: [String]

    init(root: CodeRoot, workTree: String, otherWorktrees: [String]) {
        self.root = root
        tree = TerminalCenter.resolvedPath(workTree)
        self.otherWorktrees = otherWorktrees.map(TerminalCenter.resolvedPath)
    }

    func pullsEdits(of other: CodeRoot) -> Bool {
        guard other != root else { return true }
        guard other.isMain else { return false }
        let folder = TerminalCenter.resolvedPath(other.folder.path)
        return Self.path(folder, isWithin: tree) || Self.path(tree, isWithin: folder)
    }

    func savesBuffer(of owner: CodeRoot, at path: String) -> Bool {
        guard pullsEdits(of: owner) else { return false }
        let file = TerminalCenter.resolvedPath(path)
        guard !isInAnotherWorktree(file) else { return false }
        return owner == root || Self.path(file, isWithin: tree)
    }

    private func isInAnotherWorktree(_ file: String) -> Bool {
        if otherWorktrees.contains(where: { Self.path(file, isWithin: $0) }) { return true }
        let nested = (tree.hasSuffix("/") ? tree : tree + "/") + ".claude/worktrees/"
        return file.hasPrefix(nested)
    }

    private static func path(_ path: String, isWithin folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }
}
