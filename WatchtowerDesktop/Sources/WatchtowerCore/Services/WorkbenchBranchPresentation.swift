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

    package struct ButtonLabel: Equatable, Sendable {
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

    package static func label(_ status: WorkbenchGitStatus) -> ButtonLabel {
        if status.detached {
            return ButtonLabel(text: status.head.isEmpty ? "detached" : status.head, style: .detachedHash)
        }
        return ButtonLabel(text: status.branch, style: .branch)
    }

    /// The longest branch name the header button shows whole.
    package static let maxButtonNameLength = 32

    /// A long name cut at the tail with `…`, so the button never pushes the
    /// header's view buttons away.
    package static func capped(_ name: String) -> String {
        name.count <= maxButtonNameLength ? name : String(name.prefix(maxButtonNameLength - 1)) + "…"
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

    /// The button's tooltip: the full name, plus an operation in progress,
    /// plus why it may be out of date (the reads since this status failed),
    /// plus a switch waiting for the owner's confirmation, plus a stash note
    /// the owner has not dismissed (its entry stays findable).
    package static func help(
        _ status: WorkbenchGitStatus,
        staleError: String?,
        pendingBranch: String?,
        stashEntry: String? = nil
    ) -> String {
        var lines = [status.detached ? "Detached HEAD at \(status.head)" : status.branch]
        if let pendingBranch { lines.append(pendingHelp(pendingBranch)) }
        if let stashEntry { lines.append("Stashed changes: \(stashEntry)") }
        if status.dirty {
            lines.append(status.changes > 0 ? "\(changeCount(status.changes)) not committed" : "Uncommitted changes")
        }
        if !status.upstream.isEmpty { lines.append("Upstream \(status.upstream)") }
        if !status.operation.isEmpty { lines.append("A \(status.operation) is in progress — switching is refused until it ends") }
        if let staleError { lines.append("May be out of date — \(staleError)") }
        return lines.joined(separator: "\n")
    }

    package static func pendingHelp(_ branch: String) -> String {
        "Confirm switching to \(branch)"
    }

    /// A failed `workbench git <command>` call as one line for the owner. An
    /// envelope this app cannot decode, or a CLI that does not know the
    /// command or a flag, means the CLI and the app are out of step — say
    /// what to do instead of quoting a decoder.
    package static func failureText(_ error: Error, command: String) -> String {
        if error is DecodingError || isUnknownCommand(error) {
            return "unexpected output from `watchtower workbench git \(command)` — the CLI and the app may be out of sync; "
                + "update Watchtower"
        }
        return error.localizedDescription
    }

    /// cobra's words for an unknown subcommand or flag.
    private static func isUnknownCommand(_ error: Error) -> Bool {
        guard case let CLIRunnerError.nonZeroExit(_, stderr) = error else { return false }
        return ["unknown command", "unknown flag", "unknown shorthand flag"].contains { stderr.contains($0) }
    }

    /// Case-insensitive substring match on the name; the order is kept.
    package static func filter(_ branches: [WorkbenchGitBranch], query: String) -> [WorkbenchGitBranch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return branches }
        return branches.filter { $0.name.range(of: needle, options: .caseInsensitive) != nil }
    }

    /// The row's caption for a branch whose upstream was deleted: it is not
    /// level with it, there is nothing left to compare.
    package static func upstreamCaption(_ branch: WorkbenchGitBranch) -> String? {
        branch.upstreamGone ? "upstream gone" : nil
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
    /// `stashing`: the refused call already carried `--stash` (the owner
    /// confirmed it, then a session started) — the resend keeps it.
    package static func confirmation(for result: WorkbenchGitSwitchResult, stashing: Bool) -> BranchSwitchConfirmation? {
        guard !result.switched, !result.already, !result.needsConfirmation.isEmpty else { return nil }
        let dirty = stashing || result.needsConfirmation.contains(.uncommittedChanges)
        let agent = result.needsConfirmation.contains(.agentRunning)
        var parts: [String] = []
        if agent {
            parts.append("A Claude Code session is running in this folder — the agent's files will be swapped "
                          + "under it to the ones on \(result.branch).")
        }
        if dirty {
            // Go names no count when only the stash rides along (or an old
            // CLI): no "0 changes" sentence then.
            let subject = result.changes > 0 ? "\(changeCount(result.changes)) not committed. They" : "Uncommitted changes"
            parts.append("\(subject) will be stashed (untracked files included) and stay in the stash list — "
                         + "Watchtower does not restore them after the switch.")
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

    /// What the popover says after a switch or create: `error` in red (why
    /// it did not happen), `notice` as a caption (git's warning), `stash`
    /// the entry a switch left — kept apart because it outlives the popover.
    package struct Outcome: Equatable, Sendable {
        package let error: String?
        package let notice: String?
        package let stash: StashNote?

        package init(error: String?, notice: String?, stash: StashNote? = nil) {
            self.error = error
            self.notice = notice
            self.stash = stash
        }
    }

    /// The stash entry a switch pushed. The only place the app names its
    /// sha, so it stays until the owner dismisses it.
    package struct StashNote: Equatable, Sendable {
        package let text: String
        /// Putting the changes back failed: they are only in the stash.
        package let isError: Bool
        /// The entry's message, or its sha when it has none.
        package let entry: String
    }

    package static func outcome(_ result: WorkbenchGitSwitchResult) -> Outcome {
        var errors: [String] = []
        var notices: [String] = []
        if !result.error.isEmpty {
            errors.append("git failed: \(result.error)")
        } else if !result.refused.isEmpty {
            errors.append(refusedText(result))
        } else if !result.unknownConfirmations.isEmpty {
            errors.append("Not switched: the CLI asks for a confirmation this app does not know "
                + "(\(result.unknownConfirmations.joined(separator: ", "))) — update Watchtower.")
        }
        if !result.warning.isEmpty {
            notices.append("\(result.created ? "Created" : "Switched to") \(result.branch), but git reported: \(result.warning)")
        }
        return Outcome(
            error: errors.isEmpty ? nil : errors.joined(separator: "\n"),
            notice: notices.isEmpty ? nil : notices.joined(separator: "\n"),
            stash: stashNote(result)
        )
    }

    private static func stashNote(_ result: WorkbenchGitSwitchResult) -> StashNote? {
        guard !result.stashed.isEmpty else { return nil }
        // The stack is shared by every worktree and session: the entry is
        // named by its message and got back by its id, never popped.
        let entry = result.stashMessage.isEmpty ? result.stashed : result.stashMessage
        let named = result.stashMessage.isEmpty ? entry : "\"\(entry)\""
        let apply = "git stash apply \(result.stashed)"
        if !result.stashError.isEmpty {
            return StashNote(text: "Your changes are only in the stash entry \(named) — putting them back failed: "
                             + "\(result.stashError). Get them back with \(apply).", isError: true, entry: entry)
        }
        let text = result.stashRestored
            ? "Your changes are back in the work tree; the stash entry \(named) was kept on the stack."
            : "Your changes are saved in the stash entry \(named) — get them back with \(apply)."
        return StashNote(text: text, isError: false, entry: entry)
    }

    /// Go's detail wins over the generic text, except for a failed status
    /// read, whose detail is git's own error.
    private static func refusedText(_ result: WorkbenchGitSwitchResult) -> String {
        let detail = result.refusedDetail
        switch result.refused {
        case "git_failed": return "git could not read the folder: \(detail.isEmpty ? result.error : detail)"
        case _ where !detail.isEmpty: return detail
        case "unknown_branch": return "There is no local branch with that name."
        case "checked_out_elsewhere": return "That branch is checked out in another worktree."
        case "operation_in_progress": return "A merge, rebase or similar is in progress — finish or abort it first."
        case "not_git": return "The folder is not a git work tree."
        case "git_unavailable": return "git is not available (install the Command Line Tools)."
        case "invalid_name": return "That is not a valid branch name."
        case "exists": return "A branch with that name already exists."
        default: return "Refused: \(result.refused)"
        }
    }

    private static func changeCount(_ count: Int) -> String {
        count == 1 ? "1 change is" : "\(count) changes are"
    }
}
