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

    /// Backlog 2026-09-30: an approve that failed before reaching the row
    /// (SQLITE_BUSY) leaves it `pending`; the card says why and turns Approve
    /// into a Retry that re-runs the same approve.
    func testPendingCardWithGestureErrorShowsItAndRetriesApprove() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db) }
        var approved = 0
        var retried = 0
        let view = AgentActionCardView(action: action, inFlight: false,
                                       onApprove: { approved += 1 }, onReject: {}, onRetry: { retried += 1 },
                                       gestureError: .init(verb: "approve", message: "database is locked (5) (SQLITE_BUSY)"))
        // swiftlint:disable:next trailing_closure
        XCTAssertNoThrow(try view.inspect().find(textWhere: { text, _ in text.contains("SQLITE_BUSY") }))
        XCTAssertThrowsError(try view.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try view.inspect().find(button: "Reject"))
        try view.inspect().find(button: "Retry").tap()
        XCTAssertEqual(approved, 1, "a pending row's Retry re-runs approve")
        XCTAssertEqual(retried, 0, "never apply: the row was never approved")
    }

    /// A failed Reject leaves the row `pending` too, but the prominent button
    /// must stay "Approve": a "Retry" there would approve what the owner
    /// just tried to refuse.
    func testFailedRejectKeepsApproveLabel() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db) }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                       gestureError: .init(verb: "reject", message: "SQLITE_BUSY"))
        XCTAssertNoThrow(try view.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try view.inspect().find(button: "Reject"))
        XCTAssertThrowsError(try view.inspect().find(button: "Retry"))
        XCTAssertNoThrow(try view.inspect().find(text: "SQLITE_BUSY"))
    }

    /// A failed apply writes the message to the row's own `error` too — the
    /// CLI may wrap it (`recording failure "…": …`); the card shows it once.
    func testGestureErrorRepeatingTheRowErrorRendersOnce() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "failed", error: "boom")
        }
        for message in ["boom", #"recording failure "boom": disk full"#] {
            let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                           gestureError: .init(verb: "approve", message: message))
            // swiftlint:disable:next trailing_closure
            let hits = try view.inspect().findAll(ViewType.Text.self, where: { try $0.string().contains("boom") })
            XCTAssertEqual(hits.count, 1, message)
            XCTAssertNoThrow(try view.inspect().find(button: "Retry"))
        }
    }

    /// A row decided elsewhere after the failure (the strip, another window)
    /// drops the stale red line rather than contradict its status.
    func testTerminalRowHidesAStaleGestureError() throws {
        let action = try row { db in try TestDatabase.insertAgentAction(db, status: "applied") }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {},
                                       gestureError: .init(verb: "approve", message: "SQLITE_BUSY"))
        XCTAssertThrowsError(try view.inspect().find(text: "SQLITE_BUSY"))
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
    /// shown even on a chat surface that passes no in-app navigation. Since
    /// spec 2026-09-26 §8 the label follows the generic label→key→url rule
    /// (no per-tool "Open X →" text) — `outcome`'s generic link renders it,
    /// and `links` skips a `.url` destination to avoid a duplicate.
    func testAppliedJiraCardShowsOneOpenLink() throws {
        let result = #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7"}"#
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", status: "applied", resultJSON: result)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.labelView().text().string(), "ABC-7")
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

    func testJiraIssueWriteSummaryLines() throws {
        func lines(_ tool: String, _ args: String) throws -> [String] {
            let action = try row { db in try TestDatabase.insertAgentAction(db, tool: tool, external: true, argsJSON: args) }
            return AgentActionCardView.summaryLines(for: action)
        }
        XCTAssertEqual(try lines("add_jira_comment", #"{"key":"ABC-7","body":"Ship it","reason":"r"}"#),
                       ["Issue: ABC-7", "Ship it"])
        XCTAssertEqual(try lines("transition_jira_issue", #"{"key":"ABC-7","status":"Done","reason":"r"}"#),
                       ["Issue: ABC-7 → Done"])
        XCTAssertEqual(try lines("assign_jira_issue", #"{"key":"ABC-7","assignee":"me","reason":"r"}"#),
                       ["Issue: ABC-7 · Assignee: me"], "no pin → the raw string")
        // The card names the person Execute will assign (pinned at propose),
        // not the model's search words.
        let pinned = #"{"key":"ABC-7","assignee":"alex","resolved_assignee_name":"Alex Doe","#
            + #""resolved_assignee_account_id":"acc-123","reason":"r"}"#
        XCTAssertEqual(try lines("assign_jira_issue", pinned),
                       ["Issue: ABC-7 · Assignee: Alex Doe", "asked for \"alex\" · Jira account acc-123"])
        let exact = #"{"key":"ABC-7","assignee":"Alex Doe","resolved_assignee_name":"Alex Doe","reason":"r"}"#
        XCTAssertEqual(try lines("assign_jira_issue", exact), ["Issue: ABC-7 · Assignee: Alex Doe"])
        let updateArgs = #"{"key":"ABC-7","summary":"New","priority":"High","#
            + #""labels_add":["a","b"],"labels_remove":["c"],"due_date":"2026-10-01","reason":"r"}"#
        XCTAssertEqual(
            try lines("update_jira_issue", updateArgs),
            ["Issue: ABC-7", "Summary: New", "Priority: High", "Add labels: a, b", "Remove labels: c", "Due: 2026-10-01"])
    }

    /// Any applied row with a url renders as a link titled by `label`, then
    /// `key`, then the url itself — no per-tool code for new tools.
    func testAppliedResultWithURLRendersGenericLabelledLink() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "transition_jira_issue", external: true, status: "applied",
                                               resultJSON: #"{"key":"ABC-7","url":"https://acme.atlassian.net/browse/ABC-7","label":"ABC-7 → Done"}"#,
                                               appliedAt: "2026-09-26T10:00:00Z")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.labelView().text().string(), "ABC-7 → Done")
        XCTAssertEqual(try link.url(), URL(string: "https://acme.atlassian.net/browse/ABC-7"))
    }

    func testAppliedJiraIssueWithoutLabelStillShowsTheKey() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "create_jira_issue", external: true, status: "applied",
                                               resultJSON: #"{"key":"ABC-8","url":"https://acme.atlassian.net/browse/ABC-8"}"#,
                                               appliedAt: "2026-09-26T10:00:00Z")
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertEqual(try view.inspect().find(ViewType.Link.self).labelView().text().string(), "ABC-8")
    }

    /// The generic url+label link reuses `AgentActionDestination.resultWebURL`'s
    /// http/https-only check (review round 1, Important 1) — a non-web scheme
    /// in `result.url` must never render as a clickable Link.
    func testAppliedResultWithNonWebSchemeRendersNoLink() throws {
        for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,x"] {
            let action = try row { db in
                try TestDatabase.insertAgentAction(db, tool: "transition_jira_issue", external: true, status: "applied",
                                                   resultJSON: #"{"key":"ABC-7","url":"\#(url)"}"#,
                                                   appliedAt: "2026-09-26T10:00:00Z")
            }
            let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
            XCTAssertThrowsError(try view.inspect().find(ViewType.Link.self), "\(url) must not render a Link")
        }
    }
}
