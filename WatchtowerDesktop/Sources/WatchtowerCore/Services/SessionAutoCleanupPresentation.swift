import Foundation

/// The auto-cleanup screens' copy (board #1716, spec
/// 2026-11-10-auto-cleanup-on-session-delete §1, §3, §7): the sessions
/// panel header while background cleanups run, the plain Delete dialog and
/// the Not fully cleaned row of the finished group. The mark and the notice
/// themselves are `SessionAutoCleanupOutcome` and `SessionCleanupNotice`.
package enum SessionAutoCleanupPresentation {
    /// The sessions panel header while the workbench's queue has work:
    /// "Cleaning up 2 sessions…"; nil when it has none.
    package static func cleaningHeader(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Cleaning up \(count) session\(count == 1 ? "" : "s")…"
    }

    // MARK: The Delete dialog

    package static func deleteTitle(_ title: String) -> String {
        "Delete “\(title)”?"
    }

    /// A workbench session is cleaned up once its Undo window ends; a
    /// standalone terminal has nothing to clean and keeps its old wording.
    package static func deleteMessage(isWorkbenchSession: Bool, kind: TerminalSession.Kind) -> String {
        guard isWorkbenchSession else { return AgentChoicePresentation.deleteSessionMessage(kind) }
        return "Its terminal stops. Worktrees and branches it created that are merged or pushed are removed in the background."
    }

    // MARK: The Not fully cleaned row

    /// The row's warning line: its mark, or "Cleaning up…" while Clean Up
    /// Again runs on it.
    package static func rowLine(mark: String?, cleaning: Bool) -> String {
        if cleaning { return "Cleaning up…" }
        return mark ?? "Not fully cleaned."
    }

    package static let cleanUpAgain = "Clean Up Again"
    package static let deleteAnyway = "Delete Anyway"
    package static let showInCleanUp = "Show in Clean Up"
    /// The ⋯ menu of a narrow row, for VoiceOver and the tooltip.
    package static let moreActions = "More actions"
    package static let cleanUpAgainHelp = "Run the cleanup again; on success the session goes"
    package static let deleteAnywayHelp = "Delete the session now; what was not removed stays on disk"
    package static let showInCleanUpHelp = "Open the Clean Up screen for this session"
    package static let openHelp = "Show the session's report"
}
