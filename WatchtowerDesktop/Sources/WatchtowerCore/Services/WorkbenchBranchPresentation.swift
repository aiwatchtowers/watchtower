import Foundation

/// What the owner confirms before a branch switch Go refused to make on its
/// own (`needs_confirmation`): the dialog's text and the flags the resent
/// `workbench git switch` carries.
package struct BranchSwitchConfirmation: Equatable, Sendable {
    package let branch: String
    package let title: String
    package let message: String
    package let primaryLabel: String
    /// Resend with `--stash`.
    package let stash: Bool
    /// Resend with `--agent-running --confirm-agent`.
    package let confirmAgent: Bool
}

/// The workbench header's breadcrumb and branch popover text (board target
/// #233), kept out of the views so it is testable. Pure: everything comes
/// from the `workbench git` envelopes and the board's branch targets.
package enum WorkbenchBranchPresentation {
    package enum LabelStyle: Equatable, Sendable {
        case branch
        /// Detached HEAD: the short hash, drawn in gray.
        case detachedHash
    }

    package struct Label: Equatable, Sendable {
        package let text: String
        package let style: LabelStyle
    }

    package struct Badge: Equatable, Sendable {
        package let text: String
        package let help: String
    }

    /// `~/…` for a path inside `home`; any other path unchanged.
    package static func displayPath(_ path: String, home: String) -> String {
        let root = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !root.isEmpty else { return path }
        if path == root { return "~" }
        if path.hasPrefix(root + "/") { return "~" + path.dropFirst(root.count) }
        return path
    }

    package static func label(_ status: WorkbenchGitStatus) -> Label {
        if status.detached {
            return Label(text: status.head.isEmpty ? "detached" : status.head, style: .detachedHash)
        }
        return Label(text: status.branch, style: .branch)
    }

    /// The longest branch name the header button shows whole.
    package static let maxButtonNameLength = 32

    /// A long name cut at the tail with `…`, so the button never pushes the
    /// header's view buttons away.
    package static func capped(_ name: String, limit: Int = maxButtonNameLength) -> String {
        name.count <= limit ? name : String(name.prefix(max(limit - 1, 1))) + "…"
    }

    /// `↑2`, `↓1`, `↑2 ↓1`; nil when the branch is level with its upstream
    /// (or has none).
    package static func counters(_ status: WorkbenchGitStatus) -> String? {
        var parts: [String] = []
        if status.ahead > 0 { parts.append("↑\(status.ahead)") }
        if status.behind > 0 { parts.append("↓\(status.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The `›` and the branch button show only for a readable work tree.
    package static func showsButton(_ status: WorkbenchGitStatus?) -> Bool {
        guard let status else { return false }
        return status.gitAvailable && status.git && status.statusOK
    }

    /// The button's tooltip: the full name, plus an operation in progress.
    package static func help(_ status: WorkbenchGitStatus) -> String {
        var lines = [status.detached ? "Detached HEAD at \(status.head)" : status.branch]
        if status.dirty { lines.append("\(changeCount(status.changes)) not committed") }
        if !status.upstream.isEmpty { lines.append("Upstream \(status.upstream)") }
        if !status.operation.isEmpty { lines.append("A \(status.operation) is in progress — switching is refused until it ends") }
        return lines.joined(separator: "\n")
    }

    /// Case-insensitive substring match on the name; the order is kept.
    package static func filter(_ branches: [WorkbenchGitBranch], query: String) -> [WorkbenchGitBranch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return branches }
        return branches.filter { $0.name.range(of: needle, options: .caseInsensitive) != nil }
    }

    /// Why a row is disabled: the branch is checked out in another worktree,
    /// where git refuses to check it out a second time.
    package static func disabledCaption(_ branch: WorkbenchGitBranch) -> String? {
        guard !branch.worktree.isEmpty else { return nil }
        let folder = branch.worktreeName.isEmpty
            ? URL(fileURLWithPath: branch.worktree).lastPathComponent
            : branch.worktreeName
        return "open in worktree \(folder)"
    }

    /// `#12` for the first target on the branch (open ones come first),
    /// `#12 +1` when there are more; the tooltip lists them all.
    package static func badge(for branch: String, in targets: [String: [WorkbenchBranchTarget]]) -> Badge? {
        guard let list = targets[branch], let first = list.first else { return nil }
        let text = list.count > 1 ? "#\(first.id) +\(list.count - 1)" : "#\(first.id)"
        let help = list.map { "#\($0.id) \($0.title) (\($0.status))" }.joined(separator: "\n")
        return Badge(text: text, help: help)
    }

    /// The dialog for a refused switch, or nil when there is nothing to
    /// confirm (it switched, was already there, or was refused outright).
    package static func confirmation(for result: WorkbenchGitSwitchResult) -> BranchSwitchConfirmation? {
        guard !result.switched, !result.already, !result.needsConfirmation.isEmpty else { return nil }
        let dirty = result.needsConfirmation.contains(.uncommittedChanges)
        let agent = result.needsConfirmation.contains(.agentRunning)
        var parts: [String] = []
        if agent {
            parts.append("A Claude Code session is running in this folder — the agent's files will be swapped "
                          + "under it to the ones on \(result.branch).")
        }
        if dirty {
            parts.append("\(changeCount(result.changes)) not committed. They will be stashed (untracked files "
                         + "included) and stay in the stash list — Watchtower does not restore them after the switch.")
        }
        return BranchSwitchConfirmation(
            branch: result.branch,
            title: "Switch to \(result.branch)?",
            message: parts.joined(separator: "\n\n"),
            primaryLabel: dirty ? "Stash and switch" : "Switch anyway",
            stash: dirty,
            confirmAgent: agent
        )
    }

    /// What the popover says after a switch or create that did not happen,
    /// or a stash it left behind; nil when there is nothing to say.
    package static func outcomeMessage(_ result: WorkbenchGitSwitchResult) -> String? {
        if !result.error.isEmpty {
            let restored = result.stashRestored ? " Your stashed changes were put back." : ""
            return "git failed: \(result.error)\(restored)"
        }
        if !result.refused.isEmpty {
            return result.refusedDetail.isEmpty ? refusedText(result.refused) : result.refusedDetail
        }
        if !result.unknownConfirmations.isEmpty {
            return "Not switched: the CLI asks for a confirmation this app does not know "
                + "(\(result.unknownConfirmations.joined(separator: ", "))) — update Watchtower."
        }
        return nil
    }

    /// A note to keep beside a switch that stashed the owner's changes.
    package static func stashNote(_ result: WorkbenchGitSwitchResult) -> String? {
        guard result.switched, !result.stashed.isEmpty else { return nil }
        let message = result.stashMessage.isEmpty ? "" : " (\"\(result.stashMessage)\")"
        return "Your changes are in \(result.stashed)\(message) — run git stash pop when you want them back."
    }

    private static func refusedText(_ code: String) -> String {
        switch code {
        case "unknown_branch": "There is no local branch with that name."
        case "checked_out_elsewhere": "That branch is checked out in another worktree."
        case "operation_in_progress": "A merge, rebase or similar is in progress — finish or abort it first."
        case "not_git": "The folder is not a git work tree."
        case "git_unavailable": "git is not available (install the Command Line Tools)."
        case "invalid_name": "That is not a valid branch name."
        case "exists": "A branch with that name already exists."
        default: "Refused: \(code)"
        }
    }

    private static func changeCount(_ count: Int) -> String {
        count == 1 ? "1 change is" : "\(count) changes are"
    }
}
