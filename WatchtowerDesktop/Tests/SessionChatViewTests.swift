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

    /// ⌥↓ re-reads the snapshot when the key goes down: one that went stale
    /// since the last render leaves the list's state alone and the key to the caret.
    func testOptionDownToggleChecksTheSnapshotAtKeyDown() {
        let memory = WorkchatPaneMemory()
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let live = SessionFeedLive(observedAt: observed, conversation: "c", turnActive: true,
                                   steps: [SessionLiveAction(id: "t1", tool: "Read", summary: "a.go", startedAt: observed - 3)])
        var now = observed + 1
        let toggle = {
            SessionChatView.toggleSteps(memory: memory, pane: "session-1") {
                WorkchatLivePresentation.stepsSlot(snapshot: live, error: nil, working: true, now: now)
            }
        }
        XCTAssertTrue(toggle(), "a fresh list toggles")
        XCTAssertFalse(memory.stepsOpen("session-1"))
        now = observed + WorkchatLivePresentation.staleAfter
        XCTAssertFalse(toggle(), "stale now: the key moves the caret")
        XCTAssertFalse(memory.stepsOpen("session-1"), "the hidden list's state is untouched")
    }

    func testRowEqualityIgnoresClosures() {
        let entry = SessionFeedEntry(id: "a1", kind: "agent", text: "Hello **there**")
        let blocks = MarkdownDocument.parse(entry.text)
        var toggled = 0
        let lhs = SessionChatRow(entry: entry, blocks: blocks) { toggled += 1 }
        let rhs = SessionChatRow(entry: entry, blocks: blocks) { toggled += 2 }
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
        let row = SessionChatRow(entry: event(), blocks: []) { toggled += 1 }
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

    /// A question card in the agent's text is answered as the owner's next line while the session takes lines and
    /// the agent waits; with no line to send (a subagent's run) or while the agent works it shows read-only, its
    /// questions still in view. An artifact card opens the viewer (unified chat T12, review I2).
    func testWorkchatQuestionAndArtifactCardsAct() throws {
        let text = """
        Two readings.
        :::artifact key="plan" kind="document" title="Rollout plan"
        # Plan
        :::
        ```watchtower-question
        {"questions":[{"id":"q","question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}]}
        ```
        """
        let entries = [SessionFeedEntry(id: "a", kind: "agent", text: text)]
        var sent: [String] = []
        var opened: [String] = []
        var feed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) { _ in }
        feed.onAnswer = { sent.append($0) }
        feed.onOpenArtifact = { opened.append($0.key) }
        let rows = try ChatFeedRows(messages: feed.messages, context: feed.context()).inspect()
        XCTAssertNoThrow(try rows.find(button: QuestionPartView.sendLabel), "answerable: the session takes lines")
        try rows.find(ViewType.Button.self) { (try? $0.find(text: "Rollout plan")) != nil }.tap()
        XCTAssertEqual(opened, ["plan"])
        feed.context().partActions.sendFixedText("Ship it?\n- Yes")
        XCTAssertEqual(sent, ["Ship it?\n- Yes"])

        feed.answerPending = true
        XCTAssertThrowsError(try ChatFeedRows(messages: feed.messages, context: feed.context()).inspect()
            .find(button: QuestionPartView.sendLabel), "an answer on its way: no second answer (review n1)")
        feed.answerPending = false

        feed.isWorking = true
        XCTAssertThrowsError(try ChatFeedRows(messages: feed.messages, context: feed.context()).inspect()
            .find(button: QuestionPartView.sendLabel), "not while the agent works")
        feed.isWorking = false
        feed.onAnswer = nil
        let readOnly = try ChatFeedRows(messages: feed.messages, context: feed.context()).inspect()
        XCTAssertThrowsError(try readOnly.find(button: QuestionPartView.sendLabel))
        XCTAssertNoThrow(try readOnly.find(text: "Yes"), "the questions stay readable")
    }

    /// "Load earlier" while reading older text keeps the top entry in view and pins the window; back at the newest
    /// entries the pin goes and the window ends at the newest entry again (review M1).
    func testWorkchatWindowPinsWhileReadingAndLetsGoWhenFollowing() {
        let entries = (0..<300).map { SessionFeedEntry(id: "e\($0)", kind: "agent", text: "\($0)") }
        var window = SessionFeedWindow(step: 100)
        XCTAssertEqual(window.range(total: 300), 200..<300)
        XCTAssertNil(window.loadEarlier(entries: entries), "a following window just grows")
        XCTAssertEqual(window.range(total: 300), 100..<300)

        XCTAssertFalse(window.followingChanged(false, total: 300))
        XCTAssertEqual(window.loadEarlier(entries: entries), WorkchatFeedAdapter.messageID("e100"), "keep the old top")
        XCTAssertEqual(window.range(total: 310), 0..<310, "pinned: new entries add to what is read")

        XCTAssertTrue(window.followingChanged(true, total: 310), "the anchor can go")
        XCTAssertEqual(window.range(total: 310), 10..<310, "the pin is released: the newest entries again")
    }

    /// Workchat's `system` lines are the Mac's own rows: Watchtower's line on the owner's side marked "via
    /// Watchtower", a notice that unfolds; the owner's line is ChatUI's with its time and the ask it answered as the
    /// caption. A subagent marker draws nothing (#2065): agents live in the 👥 list.
    func testWorkchatFeedDrawsSystemLinesAndCaptions() throws {
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        let subagent = SessionFeedSubagent(toolUseID: "tu1", type: "Explore", description: "Map the repo", status: "running")
        let entries = [
            SessionFeedEntry(id: "w", kind: "watchtower", at: at, text: "Rebase on main"),
            SessionFeedEntry(id: "s", kind: "subagent", subagent: subagent),
            SessionFeedEntry(id: "e", kind: "event", text: "Body", title: "Task finished", eventType: "task"),
            SessionFeedEntry(id: "a", kind: "ask_answer", at: at, text: "Yes", askID: 12, title: "Ship it?")
        ]
        var toggled: [String] = []
        let feed = WorkchatFeed(entries: entries, markdown: SessionFeedMarkdownCache(), expandedEvents: []) {
            toggled.append($0)
        }
        let context = feed.context()
        let messages = feed.messages
        let systemRow = try XCTUnwrap(context.systemRow)

        XCTAssertEqual(messages.count, 3, "no row for the subagent marker")
        XCTAssertNoThrow(try systemRow(messages[0]).inspect().find(text: "via Watchtower"))
        XCTAssertNoThrow(try systemRow(messages[0]).inspect().find(text: "Rebase on main"))
        try systemRow(messages[1]).inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(toggled, ["e"])
        XCTAssertEqual(messages[2].role, "user")
        XCTAssertNoThrow(try XCTUnwrap(context.captionView?(messages[2])).inspect().find(text: "via Watchtower"))
        XCTAssertNoThrow(try XCTUnwrap(context.ownerHeader?(messages[2])).inspect().find(text: "Ask #12"))
        XCTAssertNoThrow(try XCTUnwrap(context.ownerHeader?(messages[2])).inspect().find(text: "Ship it?"))
        XCTAssertFalse(context.rowActions.allowsCopy, "Workchat's lines carry no Copy, as before")
        XCTAssertFalse(context.rowActions.allowsEdit)
        XCTAssertFalse(context.rowActions.allowsRegenerate)
    }

    // MARK: Tail paging (#2065 Task 8)

    func testMarkerOnlyTailWithEarlierPageShowsTheFeed() {
        XCTAssertFalse(SessionChatView.showsEmptyState(dialogEmpty: true, nothingPending: true, hasEarlierPage: true),
                       "a tail of subagent markers alone still pages in earlier messages")
        XCTAssertTrue(SessionChatView.showsEmptyState(dialogEmpty: true, nothingPending: true, hasEarlierPage: false))
        XCTAssertFalse(SessionChatView.showsEmptyState(dialogEmpty: false, nothingPending: true, hasEarlierPage: false))
    }

    func testLoadingRowFollowsTheWindowAndTheEarlierPage() {
        XCTAssertTrue(SessionChatView.hasEarlier(windowHasEarlier: true, hasEarlierPage: false, pageFailed: false))
        XCTAssertTrue(SessionChatView.hasEarlier(windowHasEarlier: false, hasEarlierPage: true, pageFailed: false))
        XCTAssertFalse(SessionChatView.hasEarlier(windowHasEarlier: false, hasEarlierPage: true, pageFailed: true),
                       "a failed page waits for Retry, never a layout pass")
        XCTAssertFalse(SessionChatView.hasEarlier(windowHasEarlier: false, hasEarlierPage: false, pageFailed: false))
    }
}
