import ChatWire
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerChatText
@testable import ChatUI

@MainActor
final class SessionChatViewTests: XCTestCase {
    private func event(_ type: String = "task") -> SessionFeedEntry {
        SessionFeedEntry(id: "e1", kind: "event", text: "Body of the notice", title: "Background task finished",
                         eventType: type)
    }

    func testRowEqualityIgnoresClosures() {
        let entry = SessionFeedEntry(id: "a1", kind: "agent", text: "Hello **there**")
        let blocks = MarkdownDocument.parse(entry.text)
        var opened = 0
        let lhs = SessionChatRow(entry: entry, blocks: blocks, onOpenSubagent: { opened += 1 }, onToggle: nil)
        let rhs = SessionChatRow(entry: entry, blocks: blocks, onOpenSubagent: nil) { opened += 2 }
        XCTAssertEqual(lhs, rhs)

        var changed = entry
        changed.text = "Hello there, more"
        XCTAssertNotEqual(lhs, SessionChatRow(entry: changed, blocks: blocks))
        XCTAssertNotEqual(lhs, SessionChatRow(entry: entry, blocks: MarkdownDocument.parse("Other")))
        XCTAssertNotEqual(SessionChatRow(entry: event(), blocks: []),
                          SessionChatRow(entry: event(), blocks: [], expanded: true))
    }

    func testEventRowCollapsedByDefault() throws {
        let entry = event()
        let blocks = MarkdownDocument.parse(entry.text)
        let collapsed = SessionChatRow(entry: entry, blocks: blocks)
        XCTAssertNoThrow(try collapsed.inspect().find(text: "Background task finished"))
        XCTAssertThrowsError(try collapsed.inspect().find(text: "Body of the notice"))

        let expanded = SessionChatRow(entry: entry, blocks: blocks, expanded: true)
        XCTAssertNoThrow(try expanded.inspect().find(text: "Body of the notice"))
    }

    func testEventRowClickToggles() throws {
        var toggled = 0
        let row = SessionChatRow(entry: event(), blocks: [], onOpenSubagent: nil) { toggled += 1 }
        try row.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(toggled, 1)
    }

    func testEventIconByType() throws {
        XCTAssertNoThrow(try SessionChatRow(entry: event("task"), blocks: []).inspect().find(ViewType.Image.self) {
            try $0.actualImage().name() == "gearshape"
        })
        XCTAssertNoThrow(try SessionChatRow(entry: event("teammate"), blocks: []).inspect().find(ViewType.Image.self) {
            try $0.actualImage().name() == "envelope"
        })
    }

    func testOwnerTextKeepsLineBreaksAgentTextDoesNot() {
        XCTAssertTrue(SessionChatRow.lineBreaks(forKind: "owner"))
        XCTAssertTrue(SessionChatRow.lineBreaks(forKind: "ask_answer"))
        XCTAssertTrue(SessionChatRow.lineBreaks(forKind: "watchtower"))
        XCTAssertFalse(SessionChatRow.lineBreaks(forKind: "agent"))
        XCTAssertFalse(SessionChatRow.lineBreaks(forKind: "event"))
    }

    /// The agent's text is ChatUI's answer row (unified chat T12): its Markdown is the finished answer's text run.
    func testAgentRowRendersMarkdownBlocks() throws {
        let entry = SessionFeedEntry(id: "a2", kind: "agent", text: "# Title\n\nPlain words")
        let message = try XCTUnwrap(WorkchatFeedAdapter.messages([entry]).first)
        let row = ChatUI.ChatMessageRow(message: message, parts: ChatMessageParts.parts(for: message),
                                        context: ChatPartContext(message: message), rowActions: ChatRowActions(),
                                        isTurnRunning: false)
        XCTAssertNoThrow(try row.inspect().find(NativeMarkdownView.self))
    }

    /// Workchat's `system` lines are the Mac's own rows: Watchtower's line on the owner's side marked "via
    /// Watchtower", a subagent card that opens the run, a notice that unfolds; the owner's line is ChatUI's with its
    /// time and the ask it answered as the caption.
    func testWorkchatFeedDrawsSystemLinesAndCaptions() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let subagent = SessionFeedSubagent(toolUseID: "tu1", type: "Explore", description: "Map the repo", status: "running")
        let entries = [
            SessionFeedEntry(id: "w", kind: "watchtower", at: at, text: "Rebase on main"),
            SessionFeedEntry(id: "s", kind: "subagent", subagent: subagent),
            SessionFeedEntry(id: "e", kind: "event", text: "Body", title: "Task finished", eventType: "task"),
            SessionFeedEntry(id: "a", kind: "ask_answer", at: at, text: "Yes", askID: 12, title: "Ship it?")
        ]
        var opened: [String] = []
        var toggled: [String] = []
        let feed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: [],
                                onOpenSubagent: { opened.append($0.toolUseID) }, onToggle: { toggled.append($0) })
        let context = feed.context()
        let messages = feed.messages
        let systemRow = try XCTUnwrap(context.systemRow)

        XCTAssertNoThrow(try systemRow(messages[0]).inspect().find(text: "via Watchtower"))
        XCTAssertNoThrow(try systemRow(messages[0]).inspect().find(text: "Rebase on main"))
        try systemRow(messages[1]).inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(opened, ["tu1"])
        try systemRow(messages[2]).inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(toggled, ["e"])
        XCTAssertEqual(messages[3].role, "user")
        XCTAssertEqual(context.caption?(messages[3]), WorkchatFeedAdapter.caption(entries[3]))
        XCTAssertFalse(context.rowActions.allowsEdit)
        XCTAssertFalse(context.rowActions.allowsRegenerate)
    }
}
