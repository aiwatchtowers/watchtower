import Foundation

/// The FILES tree's root row (board #2017): the folder's name and, when git
/// reads it, its branch, an uncommitted-changes dot and the ahead/behind
/// counters — the same status the header's branch crumb shows. Without a
/// usable git status (not a repository, git missing, `git status` failed)
/// the right side stays empty; a status the later reads could not refresh
/// stays, marked out of date, as the header marks it.
package struct CodeFilesRootLine: Equatable, Sendable {
    package static let dirtyHelp = "Uncommitted changes"
    package static let emptyFolder = "No files to show."
    package static let staleLabel = "Status may be out of date"

    package let name: String
    /// The folder's full path, for the tooltip.
    package let path: String
    /// The branch (capped like the header's button), or a detached HEAD's hash.
    package let branch: WorkbenchBranchPresentation.ButtonLabel?
    /// The branch name uncapped: the tooltip and VoiceOver read it whole.
    package let fullBranch: String?
    /// Why the reads since the status failed; nil when it is current.
    package let staleError: String?
    package let dirty: Bool
    /// `↑2`, `↓1`, `↑2 ↓1`; nil when level with the upstream.
    package let counters: String?
    private let ahead: Int
    private let behind: Int

    package init(root: CodeRoot, status: WorkbenchGitStatus?, staleError: String? = nil) {
        name = root.worktreeFolderName
        path = root.folder.path
        guard let status, WorkbenchBranchPresentation.showsButton(status) else {
            branch = nil
            fullBranch = nil
            self.staleError = nil
            dirty = false
            counters = nil
            ahead = 0
            behind = 0
            return
        }
        let label = WorkbenchBranchPresentation.label(status)
        branch = .init(text: WorkbenchBranchPresentation.capped(label.text), style: label.style)
        fullBranch = label.text
        self.staleError = staleError
        dirty = status.dirty
        counters = WorkbenchBranchPresentation.counters(status)
        ahead = status.ahead
        behind = status.behind
    }

    /// The row read as one VoiceOver element.
    package var accessibilityLabel: String {
        var parts = ["Folder \(name)"]
        if let branch, let fullBranch {
            parts.append(branch.style == .detachedHash ? "detached at \(fullBranch)" : "branch \(fullBranch)")
        }
        if dirty { parts.append(Self.dirtyHelp.lowercased()) }
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if behind > 0 { parts.append("\(behind) behind") }
        if staleError != nil { parts.append(Self.staleLabel.lowercased()) }
        return parts.joined(separator: ", ")
    }

    /// The branch caption's tooltip: the full name, plus why it may be out of date.
    package var branchHelp: String {
        guard let fullBranch else { return "" }
        guard let staleError else { return fullBranch }
        return "\(fullBranch)\n\(Self.staleLabel): \(staleError)"
    }

    package static func accessibilityValue(expanded: Bool) -> String {
        expanded ? "Expanded" : "Collapsed"
    }
}

/// The FILES section's words: the header, the row menu and the git marks.
package enum CodeFilesCopy {
    package static let collapse = "Collapse files"
    package static let expand = "Expand files"
    package static let newEntry = "New file or folder"
    package static let newFile = "New File…"
    package static let newFolder = "New Folder…"
    package static let collapseAll = "Collapse all folders"
    package static let reload = "Reload the tree"
    package static let rename = "Rename…"
    package static let moveToTrash = "Move to Trash"
    package static let revealInFinder = "Reveal in Finder"
    package static let copyRelativePath = "Copy Relative Path"
    package static let gitUnavailable = "Git status unavailable — the marks may be out of date."
    package static let notCommitted = "Not committed"
    package static let holdsChanges = "Holds uncommitted changes"

    /// The caption's tooltip: a worktree names its folder; the main root has none.
    package static func captionHelp(_ root: CodeRoot) -> String {
        root.isMain ? "" : "The worktree the session on screen works in:\n\(root.folder.path)"
    }
}
