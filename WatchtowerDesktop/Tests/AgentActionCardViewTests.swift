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
        XCTAssertEqual(AgentActionCardView.title(for: action), "Create a Jira issue")
        let lines = AgentActionCardView.summaryLines(for: action)
        XCTAssertEqual(lines, ["Project: ABC · Task", "Summary: Fix login", "Description: body", "Labels: a, b"])
    }

    func testTargetSummaryLines() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, argsJSON: #"{"text":"Call Vasya","due":"2026-09-05T16:00","priority":"high","reason":"r"}"#)
        }
        XCTAssertEqual(AgentActionCardView.title(for: action), "Create a target")
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Call Vasya", "Due: 2026-09-05T16:00 · Priority: high"])
    }

    /// The card names a tool with the shared human name the Inbox cheat
    /// sheet uses (`ReactionToolCatalog`), never a second vocabulary.
    func testBriefContextCardUsesTheSharedHumanName() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "brief_context", argsJSON: #"{"summary":"s"}"#)
        }
        XCTAssertEqual(AgentActionCardView.title(for: action), "Brief me")
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: "Brief me"))
    }

    func testUnknownToolTitleFallsBackToTheToolID() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db, tool: "frobnicate") }
        XCTAssertEqual(AgentActionCardView.title(for: action), "frobnicate")
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

    /// A claimed row is mid-execution in another process — the card may only
    /// report it, never offer a second decision on it.
    func testExecutingCardShowsNoButtons() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db, status: "executing") }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertThrowsError(try view.inspect().find(button: "Approve"))
        XCTAssertThrowsError(try view.inspect().find(button: "Reject"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
        XCTAssertNoThrow(try view.inspect().find(text: "Executing…"))
    }

    /// An approve whose CLI process died before Apply claimed the row leaves
    /// it `approved` forever; Retry is what gets it out. It never reached the
    /// tool, so it carries no duplicate warning.
    func testStrandedApprovedExternalCardOffersRetryWithoutADuplicateWarning() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "approved")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(button: "Retry"))
        XCTAssertThrowsError(
            // swiftlint:disable:next trailing_closure
            try view.inspect().find(textWhere: { text, _ in text.contains("check Jira") }),
            "Apply claims the row before it runs the tool, so an approved row never reached Jira"
        )
    }

    /// The created issue's link IS the card's Open affordance — one link,
    /// shown even on a chat surface that passes no in-app navigation.
    func testAppliedJiraCardShowsOneOpenLink() throws {
        let result = #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7"}"#
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", status: "applied", resultJSON: result)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.labelView().text().string(), "Open ABC-7 →")
        XCTAssertEqual(try link.url().absoluteString, "https://acme.atlassian.net/browse/ABC-7")
        XCTAssertEqual(try view.inspect().findAll(ViewType.Link.self).count, 1)
    }

    func testAppliedIdeaCardOpenCallsBackWithItsDestination() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_idea", argsJSON: #"{"essence":"e"}"#,
                                               status: "applied", resultJSON: #"{"idea_id":42}"#)
        }
        var opened: AgentActionDestination?
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                       onOpen: { opened = $0 })
        try view.inspect().find(button: "Open →").tap()
        XCTAssertEqual(opened, .idea(42))
    }

    /// Chat surfaces pass no navigation: no in-app Open button there.
    func testAppliedCardWithoutNavigationShowsNoOpenButton() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, status: "applied", resultJSON: #"{"target_id":7}"#)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertThrowsError(try view.inspect().find(button: "Open →"))
        XCTAssertNoThrow(try view.inspect().find(text: "Task #7 created"))
    }

    func testPendingCardShowsNoOpenButton() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_idea", argsJSON: #"{"essence":"e"}"#,
                                               resultJSON: #"{"idea_id":42}"#)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                       onOpen: { _ in })
        XCTAssertThrowsError(try view.inspect().find(button: "Open →"))
    }

    func testAppliedBriefContextCardRendersTheResultSummary() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "brief_context", argsJSON: #"{"summary":"proposed"}"#,
                                               status: "applied", resultJSON: #"{"summary":"The thread agreed to ship Friday."}"#)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                       onOpen: { _ in })
        XCTAssertNoThrow(try view.inspect().find(text: "The thread agreed to ship Friday."))
        XCTAssertThrowsError(try view.inspect().find(button: "Open →"), "a brief has nothing to open")
    }

    func testReactionCardLinksItsSlackMessage() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_track", argsJSON: #"{"text":"Watch the rollout"}"#,
                                               contextType: "reaction", contextID: "2:C0ABC@1740000000.123456")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.labelView().text().string(), "Slack message ↗")
        XCTAssertEqual(try link.url().absoluteString, "https://slack.com/archives/C0ABC/p1740000000123456")
    }

    /// create_track's composer writes `text` (`internal/tools/tracks.go`).
    func testTrackSummaryReadsText() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_track", argsJSON: #"{"title":"stale","text":"Watch the rollout"}"#)
        }
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Watch the rollout"])
    }
}
