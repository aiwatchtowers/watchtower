import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The edit_confluence_page card's preview model: the word diff it renders
/// and the per-row-version memo that keeps the (up to 4 MiB) args from being
/// decoded on every render. The card's rendering and its summary lines are
/// pinned in AgentActionCardViewConfluenceTests.
@MainActor
final class AgentActionCardViewConfluencePreviewTests: XCTestCase {
    private static let confluenceArgs = AgentActionCardViewConfluenceTests.confluenceArgs

    private func row(_ configure: (Database) throws -> Void) throws -> AgentAction {
        let queue = try TestDatabase.create()
        try queue.write(configure)
        return try queue.read { db in try AgentActionQueries.fetchByConversation(db, conversationID: 1) }[0]
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

        // Another workspace's row: same id, same args length, different page
        // version — the cheap key still tells them apart.
        let sameLength = changedArgs.replacingOccurrences(of: #""base_version":7"#, with: #""base_version":8"#)
        XCTAssertEqual(sameLength.utf8.count, changedArgs.utf8.count)
        let other = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: sameLength)
        }
        XCTAssertEqual(other.id, action.id)
        XCTAssertEqual(AgentActionCardView.confluenceEdit(for: other)?.baseVersion, "8")
        XCTAssertEqual(memo.builds, start + 3, "same id and length, different content: rebuilt")
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

    /// F2: once the preview is built, rendering the card and its summary
    /// never decodes the args again — the edit_confluence_page branch is
    /// decided on the tool name, not on a Jira `key` lookup that parsed the
    /// whole (up to 4 MiB) args on every body evaluation.
    func testConfluenceCardRendersWithoutReDecodingArgs() throws {
        let unique = "Rollout plan \(UUID().uuidString)"
        let args = Self.confluenceArgs.replacingOccurrences(of: "Rollout plan", with: unique)
        let action = try row { db in
            try TestDatabase.insertAgentAction(db, tool: "edit_confluence_page", external: true, argsJSON: args)
        }
        let beforeBuild = AgentAction.argsDecodes.count
        _ = AgentActionCardView.summaryLines(for: action) // builds the memoized preview
        let start = AgentAction.argsDecodes.count
        XCTAssertEqual(start - beforeBuild, 1, "building the preview decodes the args once")
        for _ in 0..<50 {
            _ = AgentActionCardView.summaryLines(for: action)
            _ = AgentActionCardView.canApprove(action)
        }
        let view = AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
        XCTAssertNoThrow(try view.inspect().find(button: "Approve"))
        XCTAssertEqual(AgentAction.argsDecodes.count, start, "no args decode per render")
    }
}
