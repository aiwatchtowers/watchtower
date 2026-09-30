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

    // MARK: - edit_confluence_page (spec 2026-09-30 §6)

    /// The stored args after Normalize (task 4's shape): `changes[]` is what
    /// the card shows; `new_storage` is never rendered.
    private static let confluenceArgs = #"""
    {"account_id":1,"base_version":7,
     "changes":[{"kind":"replace_text","locator":"text in Plan",
                 "before":"Owner ⟦1:@Ann Lee⟧ ships on Friday.","after":"Ships on Monday.",
                 "removed":["⟦1:@Ann Lee⟧"]},
                {"kind":"replace_section","locator":"Risks",
                 "before":"None known.","after":"Late vendor sign-off.","removed":[]}],
     "edits":[],"kind":"page","new_storage":"<h2>Plan</h2><p>Ships on Monday.</p>",
     "page_id":"98765","reason":"fix the rollout day","title":"Rollout plan",
     "url":"https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout"}
    """#

    private func confluenceRow(status: String = "pending", resultJSON: String = "", error: String = "") throws -> AgentAction {
        try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true,
                                               argsJSON: Self.confluenceArgs, status: status,
                                               resultJSON: resultJSON, error: error)
        }
    }

    func testConfluenceEditSummaryReadsThePinnedChanges() throws {
        let action = try confluenceRow()
        XCTAssertEqual(AgentActionCardView.title(for: action), "Edit a Confluence page")
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Page: Rollout plan · edits version 7"])

        let edit = try XCTUnwrap(AgentActionCardView.confluenceEdit(for: action))
        XCTAssertEqual(edit.pageURL, URL(string: "https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout"))
        XCTAssertEqual(edit.changes.map(\.heading), ["text in Plan", "Section: Risks"])
        XCTAssertEqual(edit.changes.map(\.before), ["Owner ⟦1:@Ann Lee⟧ ships on Friday.", "None known."])
        XCTAssertEqual(edit.changes.map(\.after), ["Ships on Monday.", "Late vendor sign-off."])
        XCTAssertEqual(edit.changes.map(\.removesLine), ["Removes: @Ann Lee", nil])
    }

    /// Deleted words struck through in red, inserted words in green, the
    /// unchanged words plain.
    func testConfluenceDiffStylesRemovedAndAddedWords() {
        let text = AgentActionCardView.diffText(before: "Ships on Friday.", after: "Ships on Monday.")
        let runs = text.runs.map { run in
            (String(text[run.range].characters), run.swiftUI.strikethroughStyle != nil, run.swiftUI.foregroundColor)
        }
        XCTAssertEqual(runs.map(\.0), ["Ships on ", "Friday.", "Monday."])
        XCTAssertEqual(runs.map(\.1), [false, true, false])
        XCTAssertEqual(runs.map(\.2), [nil, .red, .green])
        // Colour is never the only cue: added words are underlined too.
        let underlined = text.runs.map { $0.swiftUI.underlineStyle != nil }
        XCTAssertEqual(underlined, [false, false, true])
    }

    /// The card's body re-evaluates with the chat thread (every streamed
    /// token), and the args carry the whole new page storage: the parse and
    /// the word diffs run once per (row id, args), never per render.
    func testConfluencePreviewIsBuiltOncePerRowVersion() throws {
        let unique = "Rollout plan \(UUID().uuidString)"
        let args = Self.confluenceArgs.replacingOccurrences(of: "Rollout plan", with: unique)
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: args)
        }
        let memo = ConfluenceEditMemo.shared
        let start = memo.builds

        let first = AgentActionCardView.confluenceEdit(for: action)
        XCTAssertEqual(memo.builds, start + 1)
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        _ = try view.inspect().find(text: "text in Plan")
        _ = try view.inspect().find(text: "Section: Risks")
        _ = AgentActionCardView.summaryLines(for: action)
        XCTAssertEqual(AgentActionCardView.confluenceEdit(for: action), first)
        XCTAssertEqual(memo.builds, start + 1, "renders and lookups reuse the built preview")

        let changedArgs = args.replacingOccurrences(of: unique, with: unique + " v2")
        let changed = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: changedArgs)
        }
        XCTAssertEqual(changed.id, action.id, "same row id, different args")
        XCTAssertEqual(AgentActionCardView.confluenceEdit(for: changed)?.title, unique + " v2")
        XCTAssertEqual(memo.builds, start + 2, "different args never reuse a stale preview")
    }

    /// Args without a title name the page generically, never "Page:  · …".
    func testConfluenceEditWithoutTitleFallsBackToAGenericName() throws {
        let args = Self.confluenceArgs.replacingOccurrences(of: #""title":"Rollout plan","#, with: "")
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: args)
        }
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Page: Confluence page · edits version 7"])
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertEqual(try view.inspect().find(ViewType.Link.self).labelView().text().string(),
                       "Open “Confluence page” in Confluence ↗")
    }

    /// A long unchanged stretch is shortened around an ellipsis, so a
    /// section-sized diff stays readable; the changed words are never cut.
    func testConfluenceDiffShortensLongUnchangedText() {
        let head = String(repeating: "word ", count: 200)
        let text = AgentActionCardView.diffText(before: head + "old", after: head + "new")
        let plain = String(text.characters)
        XCTAssertTrue(plain.contains(" … "))
        XCTAssertLessThan(plain.count, head.count)
        XCTAssertTrue(plain.hasSuffix("oldnew"))
    }

    func testConfluenceEditCardRendersPageLinkLocatorsAndRemovals() throws {
        let view = AgentActionCardView(action: try confluenceRow(), inFlight: false,
                                       onApprove: {}, onReject: {}, onRetry: {})
        let link = try view.inspect().find(ViewType.Link.self)
        XCTAssertEqual(try link.url(), URL(string: "https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout"))
        XCTAssertNoThrow(try view.inspect().find(text: "text in Plan"))
        XCTAssertNoThrow(try view.inspect().find(text: "Section: Risks"))
        XCTAssertNoThrow(try view.inspect().find(text: "Removes: @Ann Lee"))
        XCTAssertNoThrow(try view.inspect().find(button: "Approve"))
    }

    /// A failed write shows its error verbatim (the row's `error` column —
    /// the registry writes no result for a failed Execute), and the retry
    /// note explains the version check instead of the Jira duplicate warning.
    func testFailedConfluenceEditShowsTheErrorAndAVersionSafeRetryNote() throws {
        let conflict = "conflict: the page was edited after the preview (now v8); nothing was written"
        let view = AgentActionCardView(action: try confluenceRow(status: "failed", error: conflict),
                                       inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: conflict))
        XCTAssertNoThrow(try view.inspect().find(button: "Retry"))
        // swiftlint:disable:next trailing_closure
        XCTAssertThrowsError(try view.inspect().find(textWhere: { text, _ in text.contains("check Jira") }))
        XCTAssertNoThrow(try view.inspect().find(
            text: "Retrying writes only if the page is still at version 7; if someone edited it since, ask for a new edit."
        ))
    }

    /// Applied: the new version is named, and the page is linked once (the
    /// generic result-url link would repeat the preview's page link).
    func testAppliedConfluenceEditNamesTheNewVersionAndLinksOnce() throws {
        let result = #"{"page_id":"98765","title":"Rollout plan","url":"https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout","version":8}"#
        let view = AgentActionCardView(action: try confluenceRow(status: "applied", resultJSON: result),
                                       inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: "Saved as version 8"))
        XCTAssertEqual(try view.inspect().findAll(ViewType.Link.self).count, 1)
    }

    /// Args the card cannot read (no changes array) fall back to the raw
    /// JSON rather than an empty or invented preview.
    func testUnreadableConfluenceArgsFallBackToRawJSON() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: #"{"page_id":"1"}"#)
        }
        XCTAssertNil(AgentActionCardView.confluenceEdit(for: action))
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), [#"{"page_id":"1"}"#])
    }

    /// A page url that is not http(s) is never linked.
    func testConfluenceEditWithNonWebPageURLHasNoLink() throws {
        let args = Self.confluenceArgs.replacingOccurrences(
            of: "https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout", with: "javascript:alert(1)"
        )
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: args)
        }
        XCTAssertNil(try XCTUnwrap(AgentActionCardView.confluenceEdit(for: action)).pageURL)
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertThrowsError(try view.inspect().find(ViewType.Link.self))
    }
}
