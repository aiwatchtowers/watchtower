import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class AgentActionQueriesTests: XCTestCase {
    func testFetchByConversationOrdersAndDecodes() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "a", createdAt: "2026-09-04T10:00:01Z")
            try TestDatabase.insertAgentAction(
                db,
                tool: "create_jira_issue",
                external: true,
                argsJSON: #"{"project_key":"ABC","issue_type":"Task","summary":"Fix","reason":"r"}"#,
                conversationID: 1,
                turnID: "b",
                status: "applied",
                resultJSON: #"{"key":"ABC-7","url":"https://x/browse/ABC-7"}"#,
                createdAt: "2026-09-04T10:00:00Z",
                appliedAt: "2026-09-04T10:05:00Z"
            )
            try TestDatabase.insertAgentAction(db, conversationID: 2)
        }
        let rows = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }
        XCTAssertEqual(rows.map(\.turnID), ["b", "a"], "oldest first by created_at")
        let jira = rows[0]
        XCTAssertTrue(jira.external)
        XCTAssertEqual(jira.argString("summary"), "Fix")
        XCTAssertEqual(jira.resultString("key"), "ABC-7")
        XCTAssertTrue(jira.isTerminal)
        XCTAssertFalse(jira.canRetry)
        XCTAssertTrue(rows[1].isPending)
    }

    func testFetchDecidedAfterUsesDecidedOrApplied() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, status: "rejected", decidedAt: "2026-09-04T10:00:00Z")
            try TestDatabase.insertAgentAction(db, status: "applied", decidedAt: "2026-09-04T09:00:00Z", appliedAt: "2026-09-04T10:30:00Z")
            try TestDatabase.insertAgentAction(db, status: "pending")
            try TestDatabase.insertAgentAction(db, status: "failed", appliedAt: "2026-09-04T08:00:00Z")
        }
        let rows = try queue.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: 1, after: "2026-09-04T09:30:00Z")
        }
        XCTAssertEqual(rows.map(\.status), ["rejected", "applied"])
        XCTAssertTrue(try queue.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: 1, after: "2026-09-05T00:00:00Z")
        }.isEmpty)
    }

    /// A row decided/applied in the SAME second as the floor must still be
    /// reported — the floor is a whole-second truncation of a sub-second
    /// `Date` (`AgentActionFeed.timestampString`), so a decision landing
    /// later within that same second, after the floor moment, must not be
    /// excluded forever by every subsequent (later) floor.
    func testFetchDecidedAfterIncludesASameSecondRow() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, status: "applied", appliedAt: "2026-09-04T10:00:00Z")
        }
        let rows = try queue.read { db in
            try AgentActionQueries.fetchDecidedAfter(db, conversationID: 1, after: "2026-09-04T10:00:00Z")
        }
        XCTAssertEqual(rows.map(\.status), ["applied"], "a same-second outcome is reported once more, not dropped forever")
    }

    func testStateFlags() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, turnID: "failed", status: "failed", error: "boom")
            try TestDatabase.insertAgentAction(db, turnID: "executing", status: "executing")
            try TestDatabase.insertAgentAction(db, turnID: "approved", status: "approved")
        }
        let rows = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }
        let byTurn = Dictionary(uniqueKeysWithValues: rows.map { ($0.turnID, $0) })

        let failed = try XCTUnwrap(byTurn["failed"])
        XCTAssertTrue(failed.canRetry)
        XCTAssertFalse(failed.isPending)
        XCTAssertFalse(failed.isTerminal)
        XCTAssertFalse(failed.isExecuting)
        XCTAssertEqual(failed.error, "boom")

        // `Registry.Apply` claimed this row and is running the tool right now,
        // in another process: nothing here is the owner's to decide.
        let executing = try XCTUnwrap(byTurn["executing"])
        XCTAssertTrue(executing.isExecuting)
        XCTAssertFalse(executing.canRetry)
        XCTAssertFalse(executing.isPending)
        XCTAssertFalse(executing.isTerminal)

        // Apply accepts `approved` too, so an approve whose CLI process died
        // before the claim is retriable rather than a dead end.
        let approved = try XCTUnwrap(byTurn["approved"])
        XCTAssertTrue(approved.canRetry)
        XCTAssertFalse(approved.isExecuting)
        XCTAssertFalse(approved.isTerminal)
    }

    /// STRIP-A: the strip aggregates non-terminal proposals across every
    /// conversation (not scoped to one), newest-created first — plus (spec
    /// §4.1) a bounded tail of recently applied/rejected rows so an
    /// execute-trust tool's result (e.g. `brief_context`, which auto-applies
    /// and has no non-terminal window to be caught in) still surfaces.
    func testFetchStripReturnsNonTerminalAcrossConversations() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "pending-1", status: "pending", createdAt: "2026-09-04T10:00:00Z")
            try TestDatabase.insertAgentAction(db, conversationID: 2, turnID: "approved-1", status: "approved", createdAt: "2026-09-04T11:00:00Z")
            try TestDatabase.insertAgentAction(db, conversationID: 3, turnID: "failed-1", status: "failed", createdAt: "2026-09-04T09:00:00Z")
            try TestDatabase.insertAgentAction(db, conversationID: 1, turnID: "executing-1", status: "executing", createdAt: "2026-09-04T12:00:00Z")
            // Recent terminal rows (decided_at within the window) — must appear, after the non-terminal rows.
            try TestDatabase.insertAgentAction(
                db, conversationID: 2, turnID: "applied-recent", status: "applied",
                createdAt: "2026-09-04T13:00:00Z", decidedAt: "2026-09-04T13:00:05Z", appliedAt: "2026-09-04T13:00:05Z"
            )
            try TestDatabase.insertAgentAction(
                db, conversationID: 3, turnID: "rejected-recent", status: "rejected",
                createdAt: "2026-09-04T14:00:00Z", decidedAt: "2026-09-04T14:00:05Z"
            )
            // Old terminal rows (decided_at before the window) — must be excluded.
            try TestDatabase.insertAgentAction(
                db, conversationID: 2, turnID: "applied-old", status: "applied",
                createdAt: "2026-09-03T13:00:00Z", decidedAt: "2026-09-03T13:00:05Z", appliedAt: "2026-09-03T13:00:05Z"
            )
            try TestDatabase.insertAgentAction(
                db, conversationID: 3, turnID: "rejected-old", status: "rejected",
                createdAt: "2026-09-03T14:00:00Z", decidedAt: "2026-09-03T14:00:05Z"
            )
        }
        let rows = try queue.read { db in
            try AgentActionQueries.fetchStrip(db, terminalSince: "2026-09-04T00:00:00Z")
        }
        XCTAssertEqual(
            rows.map(\.turnID),
            ["executing-1", "approved-1", "pending-1", "failed-1", "rejected-recent", "applied-recent"],
            "newest created_at first within each group; non-terminal rows before the recent-terminal tail; old terminal rows dropped"
        )
    }

    /// The Inbox badge counts what waits on the owner: pending + failed
    /// (retriable); in-flight and terminal rows are not decisions.
    func testAwaitingOwnerCountCountsPendingAndFailedOnly() throws {
        let dbq = try TestDatabase.create()
        try dbq.write { db in
            _ = try TestDatabase.insertAgentAction(db, turnID: "t1", status: "pending")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t2", status: "failed")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t3", status: "approved")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t4", status: "executing")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t5", status: "applied")
            _ = try TestDatabase.insertAgentAction(db, turnID: "t6", status: "rejected")
        }
        XCTAssertEqual(try dbq.read { try AgentActionQueries.awaitingOwnerCount($0) }, 2)
    }
}
