import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class AgentActionCardViewConfluenceTests: XCTestCase {
    private func row(_ configure: (Database) throws -> Void) throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write(configure)
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
    }

    // MARK: - edit_confluence_page (spec 2026-09-30 §6)

    /// The stored args after Normalize (task 4's shape): `changes[]` is what
    /// the card shows; `new_storage` is never rendered.
    static let confluenceArgs = #"""
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

    private func confluenceRow(status: String = "pending", error: String = "") throws -> AgentAction {
        try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true,
                                               argsJSON: Self.confluenceArgs, status: status,
                                               error: error)
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

    /// Args the card cannot read (no changes array) show one short line —
    /// never an empty or invented preview, and never the raw JSON (which
    /// carries the whole new page storage, up to 4 MiB) in a Text.
    func testUnreadableConfluenceEditShowsAShortLine() throws {
        let storage = String(repeating: "<p>x</p>", count: 1000)
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true,
                                               argsJSON: #"{"new_storage":"\#(storage)","base_version":7}"#)
        }
        XCTAssertNil(AgentActionCardView.confluenceEdit(for: action))
        XCTAssertEqual(AgentActionCardView.summaryLines(for: action), ["Unreadable Confluence edit proposal"])
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

    /// A caveat Normalize pinned (a failed user-name lookup) shows on the card.
    func testConfluenceEditShowsPinnedNotes() throws {
        let note = "User names unavailable — mentions show account ids"
        let args = Self.confluenceArgs.replacingOccurrences(of: #""edits":[],"#, with: #""edits":[],"notes":["\#(note)"],"#)
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: args)
        }
        XCTAssertEqual(AgentActionCardView.confluenceEdit(for: action)?.notes, [note])
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: note))

        let plain = try confluenceRow()
        XCTAssertEqual(AgentActionCardView.confluenceEdit(for: plain)?.notes, [])
    }

    /// F7: an edit_confluence_page proposal the card cannot read offers no
    /// Approve — approving would write a page the owner never saw — only
    /// Reject. Other tools keep Approve.
    func testUnreadableConfluenceEditOffersNoApprove() throws {
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true,
                                               argsJSON: #"{"new_storage":"<p>x</p>","base_version":7}"#)
        }
        XCTAssertFalse(AgentActionCardView.canApprove(action))
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertThrowsError(try view.inspect().find(button: "Approve"))
        XCTAssertNoThrow(try view.inspect().find(button: "Reject"))

        XCTAssertTrue(AgentActionCardView.canApprove(try confluenceRow()))
        let other = try row { db in try TestDatabase.insertAgentAction(db) }
        XCTAssertTrue(AgentActionCardView.canApprove(other))
    }
}
