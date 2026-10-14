import XCTest
import WatchtowerCore

/// `SessionDeleteCleanupChoice` and its dialog line (board #535, spec
/// 2026-10-12-session-cleanup §12): what the Delete dialog shows is all
/// Delete and Clean Up may apply.
final class SessionDeleteCleanupChoiceTests: XCTestCase {
    private typealias Item = SessionCleanupItem

    private let busyWorktree = Item(key: "worktree:/tmp/example/x", kind: .worktree, name: "x", branch: "feat/x",
                                    action: .keep, reason: .known(.processRunning))
    private let branchInIt = Item(key: "branch:feat/x", kind: .branch, name: "feat/x",
                                  action: .keep, reason: .known(.checkedOut))

    func testUnknownKindsAreNeitherShownNorOffered() {
        let plan = SessionCleanupPlan(items: [
            Item(key: "gizmo:1", kind: .unknown("gizmo"), action: .remove),
            Item(key: "branch:a", kind: .branch, name: "a", action: .remove)
        ])
        XCTAssertEqual(SessionDeleteCleanupChoice(plan: plan).shownKeys, ["branch:a"])

        let unknownOnly = SessionCleanupPlan(items: [Item(key: "gizmo:1", kind: .unknown("gizmo"), action: .remove)])
        XCTAssertFalse(SessionDeleteCleanupChoice(plan: unknownOnly).offersCleanup)
        XCTAssertNil(SessionCleanupPresentation.offerLine(unknownOnly))
    }

    func testWorktreeKeptForARunningProcessIsShownForAfterTheClose() {
        let other = Item(key: "branch:feat/y", kind: .branch, name: "feat/y", action: .keep, reason: .known(.checkedOut))
        let plan = SessionCleanupPlan(items: [busyWorktree, branchInIt, other])
        let choice = SessionDeleteCleanupChoice(plan: plan)

        XCTAssertEqual(choice.afterClose.map(\.key), [busyWorktree.key, branchInIt.key])
        XCTAssertTrue(choice.needsReplan)
        XCTAssertTrue(choice.offersCleanup)
        XCTAssertEqual(choice.kept.map(\.key), ["branch:feat/y"], "checked out in another worktree: kept")
        XCTAssertEqual(SessionCleanupPresentation.offerLine(choice),
                       "After the terminal closes: 1 worktree, 1 branch, if nothing else runs there. "
                           + "Kept: 1 branch — checked out.")
    }

    func testOtherKeepReasonsStayKept() {
        let dirty = Item(key: "worktree:/tmp/example/z", kind: .worktree, name: "z", action: .keep,
                         reason: .known(.uncommittedChanges))
        let choice = SessionDeleteCleanupChoice(plan: SessionCleanupPlan(items: [dirty]))
        XCTAssertFalse(choice.offersCleanup)
        XCTAssertFalse(choice.needsReplan)
    }

    func testReplanAppliesOnlyShownKeysNowRemovable() {
        let choice = SessionDeleteCleanupChoice(plan: SessionCleanupPlan(items: [busyWorktree, branchInIt]))
        let replan = SessionCleanupPlan(items: [
            Item(key: busyWorktree.key, kind: .worktree, action: .remove),
            Item(key: branchInIt.key, kind: .branch, action: .keep, reason: .known(.unpushedCommits)),
            Item(key: "branch:never-shown", kind: .branch, action: .remove)
        ])
        XCTAssertEqual(choice.keysToApply(after: replan), [busyWorktree.key])
        XCTAssertEqual(choice.keptItems(in: replan).map(\.key), [branchInIt.key])
    }

    func testKeptNotice() {
        XCTAssertNil(SessionCleanupPresentation.keptAfterDeleteNotice(title: "Fix", kept: []))
        let kept = Item(key: "branch:feat/x", kind: .branch, name: "feat/x", action: .keep,
                        reason: .known(.unpushedCommits))
        XCTAssertEqual(SessionCleanupPresentation.keptAfterDeleteNotice(title: "Fix", kept: [kept]),
                       "“Fix” deleted; 1 item was kept: feat/x — unpushed commits")
        XCTAssertEqual(SessionCleanupPresentation.keptAfterDeleteNotice(title: "Fix", kept: [kept, busyWorktree]),
                       "“Fix” deleted; 2 items were kept: feat/x — unpushed commits; x — a process is running in it")
    }
}
