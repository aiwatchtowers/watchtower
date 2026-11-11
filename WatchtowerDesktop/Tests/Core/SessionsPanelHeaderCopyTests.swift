import XCTest
@testable import WatchtowerCore

/// The auto-cleanup screens' copy (spec
/// 2026-11-10-auto-cleanup-on-session-delete §1, §3, §7), word for word:
/// the sessions panel header, the Delete dialog, the Not fully cleaned
/// row and the clean notice's lead.
final class SessionsPanelHeaderCopyTests: XCTestCase {
    typealias Copy = SessionAutoCleanupPresentation

    func testCleaningHeaderCopy() {
        XCTAssertEqual(Copy.cleaningHeader(count: 1), "Cleaning up 1 session…")
        XCTAssertEqual(Copy.cleaningHeader(count: 2), "Cleaning up 2 sessions…")
        XCTAssertNil(Copy.cleaningHeader(count: 0))
    }

    func testDeleteDialogCopy() {
        XCTAssertEqual(Copy.deleteTitle("Fix login flow"), "Delete “Fix login flow”?")
        XCTAssertEqual(
            Copy.deleteMessage(isWorkbenchSession: true, kind: .agent(.claude)),
            "Its terminal stops. Worktrees and branches it created that are merged or pushed are removed in the background."
        )
        XCTAssertEqual(
            Copy.deleteMessage(isWorkbenchSession: false, kind: .agent(.codex)),
            AgentChoicePresentation.deleteSessionMessage(.agent(.codex)),
            "a standalone terminal has no worktrees to clean up"
        )
        XCTAssertEqual(Copy.deleteButton, "Delete")
        XCTAssertEqual(Copy.cancelButton, "Cancel")
    }

    func testNotFullyCleanedRowCopy() {
        let mark = "Not fully cleaned: 1 worktree — a process is running in it."
        XCTAssertEqual(Copy.rowLine(mark: mark, cleaning: false), mark)
        XCTAssertEqual(Copy.rowLine(mark: mark, cleaning: true), "Cleaning up…")
        XCTAssertEqual(Copy.rowLine(mark: nil, cleaning: true), "Cleaning up…")
        XCTAssertEqual(Copy.rowLine(mark: nil, cleaning: false), "Not fully cleaned.")
        XCTAssertEqual(Copy.cleanUpAgain, "Clean Up Again")
        XCTAssertEqual(Copy.deleteAnyway, "Delete Anyway")
        XCTAssertEqual(Copy.showInCleanUp, "Show in Clean Up")
        XCTAssertEqual(Copy.moreActions, "More actions")
        XCTAssertEqual(Copy.cleanUpAgainHelp, "Run the cleanup again; on success the session goes")
        XCTAssertEqual(Copy.deleteAnywayHelp, "Delete the session now; what was not removed stays on disk")
        XCTAssertEqual(Copy.showInCleanUpHelp, "Open the Clean Up screen for this session")
        XCTAssertEqual(Copy.openHelp, "Show the session's report")
    }

    func testNoticeLead() {
        let single = SessionCleanupNotice(text: "Cleaned up “Fix login flow”: removed 3 worktrees and 12 branches (~2.1 GB).")
        XCTAssertEqual(single.lead, "Cleaned up")
        XCTAssertEqual(single.rest, " “Fix login flow”: removed 3 worktrees and 12 branches (~2.1 GB).")
        let joined = SessionCleanupNotice(text: "Cleaned up 4 sessions: removed 9 worktrees and 31 branches (~6.8 GB).")
        XCTAssertEqual(joined.lead, "Cleaned up 4 sessions")
        XCTAssertEqual(joined.rest, ": removed 9 worktrees and 31 branches (~6.8 GB).")
        XCTAssertEqual(joined.lead + joined.rest, joined.text)
    }
}
