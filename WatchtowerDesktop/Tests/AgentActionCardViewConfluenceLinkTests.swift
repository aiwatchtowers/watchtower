import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The edit_confluence_page card's links: the page link the preview renders
/// (and its fallbacks), the locators under it, and the single link an
/// applied edit keeps. Summary lines and approve/retry state are pinned in
/// AgentActionCardViewConfluenceTests.
@MainActor
final class AgentActionCardViewConfluenceLinkTests: XCTestCase {
    private static let confluenceArgs = AgentActionCardViewConfluenceTests.confluenceArgs

    private func row(_ configure: (Database) throws -> Void) throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write(configure)
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
    }

    private func confluenceRow(status: String = "pending", resultJSON: String = "") throws -> AgentAction {
        try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true,
                                               argsJSON: Self.confluenceArgs, status: status,
                                               resultJSON: resultJSON)
        }
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

    /// Applied: the new version is named, and the page is linked once (the
    /// generic result-url link would repeat the preview's page link).
    func testAppliedConfluenceEditNamesTheNewVersionAndLinksOnce() throws {
        let result = #"{"page_id":"98765","title":"Rollout plan","url":"https://example.atlassian.net/wiki/spaces/ENG/pages/98765/Rollout","version":8}"#
        let view = AgentActionCardView(action: try confluenceRow(status: "applied", resultJSON: result),
                                       inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(text: "Saved as version 8"))
        XCTAssertEqual(try view.inspect().findAll(ViewType.Link.self).count, 1)
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
