import XCTest
@testable import WatchtowerCore

/// The background cleanup's outcome after a session delete (spec
/// 2026-11-10-auto-cleanup-on-session-delete §3): every Go reason code in a
/// group, the clean notice and the Not fully cleaned mark, word for word.
final class SessionAutoCleanupOutcomeTests: XCTestCase {
    typealias Outcome = SessionAutoCleanupOutcome

    static let goFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Core
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerDesktop
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("internal/sessioncleanup/testdata/reason_codes.json")

    // MARK: Helpers

    private func worktree(
        _ name: String,
        bytes: Int64 = 0,
        done: Bool = false,
        reason: String? = nil,
        error: String = ""
    ) -> SessionCleanupItem {
        SessionCleanupItem(
            key: "worktree:/tmp/acme/\(name)", kind: .worktree, name: name,
            bytes: bytes, bytesKnown: true, action: done || reason == nil ? .remove : .keep,
            reason: reason.map(SessionCleanupReason.init(code:)), done: done, error: error
        )
    }

    private func branch(_ name: String, done: Bool = false, reason: String? = nil) -> SessionCleanupItem {
        SessionCleanupItem(
            key: "branch:\(name)", kind: .branch, name: name,
            action: done || reason == nil ? .remove : .keep,
            reason: reason.map(SessionCleanupReason.init(code:)), done: done
        )
    }

    private func result(_ items: [SessionCleanupItem]) -> SessionCleanupPlan {
        let removed = items.filter { $0.done && $0.kind == .worktree }.reduce(Int64(0)) { $0 + $1.bytes }
        return SessionCleanupPlan(mode: "apply", items: items, removedBytes: removed, removedBytesKnown: true)
    }

    private func keptItem(_ code: String) -> SessionCleanupItem {
        SessionCleanupItem(key: "branch:x", kind: .branch, action: .keep, reason: SessionCleanupReason(code: code))
    }

    // MARK: Groups

    /// Spec §3's table, literally.
    private static let specTable: [String: CleanupItemGroup] = [
        "uncommitted_changes": .keptOnPurpose,
        "unpushed_commits": .keptOnPurpose,
        "operation_in_progress": .keptOnPurpose,
        "locked": .keptOnPurpose,
        "contains_worktree": .keptOnPurpose,
        "not_this_session": .notOurs,
        "existed_before_session": .notOurs,
        "created_unknown": .notOurs,
        "main_folder": .notOurs,
        "workbench_folder": .notOurs,
        "claude_home": .notOurs,
        "default_branch": .notOurs,
        "checked_out": .notOurs,
        "git_refused": .couldNot,
        "moved": .couldNot,
        "process_running": .couldNot,
        "process_unknown": .couldNot,
        "session_in_it": .couldNot,
        "check_failed": .couldNot,
        "bundle_unreadable": .couldNot,
        "not_attempted": .couldNot
    ]

    func testEveryGoReasonCodeIsPlaced() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.goFixture)) as? [String: Any]
        let codes = try XCTUnwrap(raw?["reason_codes"] as? [String], "reason_codes.json has no reason_codes")
        XCTAssertFalse(codes.isEmpty)
        for code in codes {
            guard case .known = SessionCleanupReason(code: code) else {
                XCTFail("Go reason code \(code) is not in SessionCleanupReason.Code: add the case and place it "
                    + "in SessionAutoCleanupOutcome.group(reason:)")
                continue
            }
        }
        for (code, group) in Self.specTable {
            XCTAssertTrue(codes.contains(code), "spec code \(code) is not in Go's list")
            XCTAssertEqual(Outcome.group(keptItem(code)), group, code)
        }
    }

    func testUnknownReasonIsCouldNot() {
        XCTAssertEqual(Outcome.group(keptItem("some_new_reason")), .couldNot)
    }

    func testItemStatesGroup() {
        XCTAssertEqual(Outcome.group(worktree("a", done: true)), .removed)
        XCTAssertEqual(Outcome.group(worktree("a", error: "git failed")), .couldNot)
        // A removal an apply left pending did not happen.
        XCTAssertEqual(Outcome.group(worktree("a")), .couldNot)
        XCTAssertEqual(
            Outcome.group(SessionCleanupItem(key: "branch:x", kind: .branch, action: .keep)), .couldNot)
        XCTAssertEqual(
            Outcome.group(SessionCleanupItem(key: "branch:x", kind: .branch, action: .unknown("later"))), .couldNot)
    }

    // MARK: Clean notice

    func testCleanNoticeCopy() {
        let full = result(
            [worktree("a", bytes: 700_000_000, done: true), worktree("b", bytes: 700_000_000, done: true),
             worktree("c", bytes: 700_000_000, done: true)]
                + (1...12).map { branch("b\($0)", done: true) }
        )
        XCTAssertEqual(
            Outcome.evaluate(result: full, title: "T", runError: nil),
            .clean(SessionCleanupNotice(text: "Cleaned up “T”: removed 3 worktrees and 12 branches (~2.1 GB)."))
        )

        let kept = result([
            worktree("a", bytes: 700_000_000, done: true), worktree("b", bytes: 700_000_000, done: true),
            branch("feat/x", reason: "unpushed_commits"),
            branch("main", reason: "default_branch")
        ])
        XCTAssertEqual(
            Outcome.evaluate(result: kept, title: "T", runError: nil),
            .clean(SessionCleanupNotice(text: "Cleaned up “T”: removed 2 worktrees (~1.4 GB). Kept 1 branch — unpushed commits."))
        )

        let nothing = result([branch("main", reason: "default_branch")])
        XCTAssertEqual(Outcome.evaluate(result: nothing, title: "T", runError: nil), .clean(nil))
    }

    func testJoinedNoticeCopy() {
        let one = result([worktree("a", bytes: 1_000_000_000, done: true), branch("a", done: true)])
        let two = result([worktree("b", bytes: 500_000_000, done: true), branch("b", reason: "unpushed_commits")])
        let three = result([branch("c", done: true)])
        let four = result([])
        XCTAssertEqual(
            SessionCleanupNotice.joined([("A", one), ("B", two), ("C", three), ("D", four)]),
            SessionCleanupNotice(
                text: "Cleaned up 4 sessions: removed 2 worktrees and 2 branches (~1.5 GB). Kept 1 branch — unpushed commits."
            )
        )
        XCTAssertEqual(
            SessionCleanupNotice.joined([("A", one)]),
            SessionCleanupNotice(text: "Cleaned up “A”: removed 1 worktree and 1 branch (~1.0 GB).")
        )
        XCTAssertNil(SessionCleanupNotice.joined([("D", four), ("E", four)]))
        XCTAssertNil(SessionCleanupNotice.joined([]))
    }

    // MARK: Not fully cleaned

    func testMarkCopy() {
        let busy = result([
            branch("a", done: true),
            worktree("a", bytes: 1_000, reason: "process_running"),
            branch("feat/x", reason: "unpushed_commits")
        ])
        XCTAssertEqual(
            Outcome.evaluate(result: busy, title: "T", runError: nil),
            .notFullyCleaned(mark: "Not fully cleaned: 1 worktree — a process is running in it.")
        )

        let mixed = result([
            worktree("a", reason: "git_refused"), branch("b", reason: "moved"), branch("c", reason: "moved")
        ])
        XCTAssertEqual(
            Outcome.evaluate(result: mixed, title: "T", runError: "watchtower exited with code 1"),
            .notFullyCleaned(mark: "Not fully cleaned: 1 worktree, 2 branches — git refused, moved since the check.")
        )

        let failed = result([worktree("a", error: "permission denied")])
        XCTAssertEqual(
            Outcome.evaluate(result: failed, title: "T", runError: nil),
            .notFullyCleaned(mark: "Not fully cleaned: 1 worktree — could not be removed.")
        )
    }

    func testRunErrorMark() {
        XCTAssertEqual(
            Outcome.evaluate(result: nil, title: "T", runError: "watchtower exited with code 1"),
            .notFullyCleaned(mark: "Not fully cleaned: the cleanup could not run — watchtower exited with code 1.")
        )
        // A run that failed as a whole fails even with a clean-looking result.
        XCTAssertEqual(
            Outcome.evaluate(result: result([]), title: "T", runError: "watchtower exited with code 1"),
            .notFullyCleaned(mark: "Not fully cleaned: the cleanup could not run — watchtower exited with code 1.")
        )
        XCTAssertEqual(
            Outcome.evaluate(result: nil, title: "T", runError: nil),
            .notFullyCleaned(mark: "Not fully cleaned: the cleanup could not run — it printed no result.")
        )
    }

    func testTimeoutMark() {
        XCTAssertEqual(
            Outcome.evaluate(result: nil, title: "T", runError: Outcome.timeoutRunError),
            .notFullyCleaned(mark: "Not fully cleaned: the cleanup took longer than 10 minutes.")
        )
    }
}
