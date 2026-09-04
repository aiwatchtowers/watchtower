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

    func testStateFlags() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertAgentAction(db, status: "failed", error: "boom")
        }
        let row = try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
        XCTAssertTrue(row.canRetry)
        XCTAssertFalse(row.isPending)
        XCTAssertFalse(row.isTerminal)
        XCTAssertEqual(row.error, "boom")
    }
}
