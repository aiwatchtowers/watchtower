import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AgentActionCardViewTests: XCTestCase {
    private func row(_ configure: (Database) throws -> Void) throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write(configure)
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
    }

    func testJiraSummaryLinesAndTitle() throws {
        let args = #"{"project_key":"ABC","issue_type":"Task","summary":"Fix login","description":"body","labels":["a","b"],"reason":"r"}"#
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, argsJSON: args)
        }
        XCTAssertEqual(AgentActionCardView.title(for: action), "Create Jira issue")
        let lines = AgentActionCardView.summaryLines(for: action)
        XCTAssertEqual(lines, ["Project: ABC · Task", "Summary: Fix login", "Description: body", "Labels: a, b"])
    }

    func testTargetSummaryLines() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, argsJSON: #"{"text":"Call Vasya","due":"2026-09-05T16:00","priority":"high","reason":"r"}"#)
        }
        XCTAssertEqual(AgentActionCardView.title(for: action), "Create task")
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Call Vasya", "Due: 2026-09-05T16:00 · Priority: high"])
    }

    func testPendingCardShowsApproveAndReject() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db) }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try view.inspect().find(button: "Reject"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
    }

    func testFailedExternalCardShowsRetryWithDuplicateWarning() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "failed", error: "boom")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(button: "Retry"))
        XCTAssertNoThrow(try view.inspect().find(text: "boom"))
        // swiftlint:disable:next trailing_closure
        XCTAssertNoThrow(try view.inspect().find(textWhere: { text, _ in text.contains("check Jira") }))
    }

    func testAppliedJiraCardShowsLink() throws {
        let result = #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7"}"#
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", status: "applied", resultJSON: result)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: "ABC-7"))
    }
}
