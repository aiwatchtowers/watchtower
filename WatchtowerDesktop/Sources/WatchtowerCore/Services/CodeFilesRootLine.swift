import Foundation

/// The FILES tree's root row (board #2017): the folder's name and, when git
/// reads it, its branch, an uncommitted-changes dot and the ahead/behind
/// counters — the same status the header's branch crumb shows. Without a
/// usable git status (not a repository, git missing, the read failed) the
/// right side stays empty.
package struct CodeFilesRootLine: Equatable, Sendable {
    package static let dirtyHelp = "Uncommitted changes"
    package static let emptyFolder = "This folder is empty."

    package let name: String
    /// The folder's full path, for the tooltip.
    package let path: String
    /// The branch (capped like the header's button), or a detached HEAD's hash.
    package let branch: WorkbenchBranchPresentation.ButtonLabel?
    package let dirty: Bool
    /// `↑2`, `↓1`, `↑2 ↓1`; nil when level with the upstream.
    package let counters: String?
    private let ahead: Int
    private let behind: Int

    package init(root: CodeRoot, status: WorkbenchGitStatus?) {
        name = root.worktreeFolderName
        path = root.folder.path
        guard let status, WorkbenchBranchPresentation.showsButton(status) else {
            branch = nil
            dirty = false
            counters = nil
            ahead = 0
            behind = 0
            return
        }
        let label = WorkbenchBranchPresentation.label(status)
        branch = .init(text: WorkbenchBranchPresentation.capped(label.text), style: label.style)
        dirty = status.dirty
        counters = WorkbenchBranchPresentation.counters(status)
        ahead = status.ahead
        behind = status.behind
    }

    /// The row read as one VoiceOver element.
    package var accessibilityLabel: String {
        var parts = ["Folder \(name)"]
        if let branch {
            parts.append(branch.style == .detachedHash ? "detached at \(branch.text)" : "branch \(branch.text)")
        }
        if dirty { parts.append(Self.dirtyHelp.lowercased()) }
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if behind > 0 { parts.append("\(behind) behind") }
        return parts.joined(separator: ", ")
    }

    package static func accessibilityValue(expanded: Bool) -> String {
        expanded ? "Expanded" : "Collapsed"
    }
}

/// The FILES header's words: its toggle and its icon buttons.
package enum CodeFilesHeaderCopy {
    package static let collapse = "Collapse files"
    package static let expand = "Expand files"
    package static let newEntry = "New file or folder"
    package static let newFile = "New File…"
    package static let newFolder = "New Folder…"
    package static let collapseAll = "Collapse all folders"
    package static let reload = "Reload the tree"

    /// The caption's tooltip: a worktree names its folder; the main root has none.
    package static func captionHelp(_ root: CodeRoot) -> String {
        root.isMain ? "" : "The worktree the session on screen works in:\n\(root.folder.path)"
    }
}
