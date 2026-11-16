import ChatUI
import ChatWire
import GRDB
import XCTest
@testable import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// A `ChatClient` that records each operation and answers from a script; no socket.
final class RecordingChatClient: ChatClient, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ChatOperation] = []
    /// Answers by operation; nil applies it with no result.
    var answer: @Sendable (ChatOperation) -> ChatEcho? = { _ in nil }

    var ops: [ChatOperation] { lock.withLock { recorded } }

    var turns: [ChatTurnRequest] {
        ops.compactMap { op in
            guard case .turn(let request) = op else { return nil }
            return request
        }
    }

    func send(_ op: ChatOperation) async throws -> ChatEcho {
        lock.withLock { recorded.append(op) }
        return answer(op) ?? .applied(.none)
    }

    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { _ in } }
    func list() -> AsyncStream<ChatListUpdate> { AsyncStream { _ in } }
    var reachability: AsyncStream<ChatReachability> { AsyncStream { _ in } }
}

/// The Mac chat's window shell over ChatUI's models (unified chat T8).
@MainActor
final class ChatViewModelShellTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var client: RecordingChatClient!
    private var vm: ChatViewModel!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        client = RecordingChatClient()
        client.answer = { op in
            switch op {
            case .new: .applied(.conversation(id: 9))
            case .turn: .applied(.turn(ChatTurnStarted(userMessageID: 1, assistantMessageID: 2, turnID: "t1")))
            default: nil
            }
        }
        vm = ChatViewModel(client: client, dbPool: pool)
    }

    override func tearDown() {
        vm.conversation.stop()
        TestDatabase.cleanup(path: path)
    }

    private func feed(_ id: Int64, messages: [ChatFeed.Message] = []) -> ChatFeed {
        ChatFeed(conversation: ChatFeed.Conversation(id: id, title: "Plan"), messages: messages)
    }

    /// ⌘/: the turn carries the current-screen block, and the stored text is the typed text alone.
    func testHelpPanelSendsScreenContext() async throws {
        vm.select(conversationID: 4)
        vm.conversation.store.apply(.snapshot(feed(4)))
        vm.composer.draft = "How do I add a source?"
        await vm.sendDraft(screen: ScreenContext(tab: "connections", selected: "Slack"))
        let turn = try XCTUnwrap(client.turns.last)
        XCTAssertEqual(turn.text, "How do I add a source?", "the stored owner text is unaffected")
        XCTAssertEqual(turn.screenContext, ScreenContext(tab: "connections", selected: "Slack").block)
        XCTAssertEqual(vm.composer.draft, "", "applied: the field clears")

        vm.composer.draft = "And in the chat window?"
        await vm.sendDraft()
        XCTAssertNil(client.turns.last?.screenContext)
    }

    /// The landing's first send creates the chat in the landing's project with the pill's routing, and the
    /// chat is then the one on screen.
    func testLandingFirstSendCreatesTheChatThere() async throws {
        var created: Int64?
        vm.onConversationCreated = { created = $0 }
        vm.showLanding(inProject: 5)
        vm.switchProvider(.codex)
        vm.composer.draft = "Start the brief"
        await vm.sendDraft()
        guard case let .new(projectID, routing)? = client.ops.first else { return XCTFail("no chat_new first") }
        XCTAssertEqual(projectID, 5)
        XCTAssertEqual(routing, ChatRouting(mode: "pinned", provider: "codex", model: nil))
        XCTAssertEqual(client.turns.first?.conversationID, 9)
        XCTAssertEqual(created, 9)
        XCTAssertEqual(vm.conversationID, 9)
        XCTAssertFalse(vm.isOnLanding)
    }

    /// The picked mentions still in the text and the `/` skill go in the turn's compose.
    func testPickedMentionsAndSkillRideAlong() async throws {
        vm.select(conversationID: 4)
        vm.conversation.store.apply(.snapshot(feed(4)))
        client.answer = { op in
            if case .entitySearch = op { return .applied(.entities([ChatEntityHit(kind: "jira", id: "PAY-1", label: "PAY-1")])) }
            if case .turn = op { return .applied(.turn(ChatTurnStarted(userMessageID: 1, assistantMessageID: 2, turnID: "t"))) }
            return nil
        }
        vm.picker.update(text: "look at @PA", cursor: 11)
        await vm.picker.searchSettled()
        let edit = try XCTUnwrap(vm.picker.accept(index: 0, text: "look at @PA", cursor: 11))
        vm.composer.draft = edit.text
        await vm.sendDraft()
        let compose = try XCTUnwrap(client.turns.last?.compose)
        XCTAssertEqual(compose.mentions, [ChatCompose.Mention(kind: "jira", id: "PAY-1", label: "PAY-1")])
        XCTAssertTrue(vm.picker.mentions.isEmpty, "sent: the picker starts over")
    }

    /// Switching chats keeps each chat's draft for it.
    func testEachChatKeepsItsDraft() {
        vm.select(conversationID: 4)
        vm.composer.draft = "for four"
        vm.select(conversationID: 5)
        XCTAssertEqual(vm.composer.draft, "")
        vm.composer.draft = "for five"
        vm.select(conversationID: 4)
        XCTAssertEqual(vm.composer.draft, "for four")
    }

    /// The feed caps a reply's text at 40 000 characters; the Mac shows the whole stored answer.
    func testACutReplyShowsItsWholeText() async throws {
        let whole = String(repeating: "x", count: 41_000)
        let (conv, reply) = try await pool.write { d -> (Int64, Int64) in
            let conv = try TestDatabase.insertChatConversation(d, title: "Long")
            let reply = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: whole)
            return (conv, reply)
        }
        vm.select(conversationID: conv)
        let cut = ChatFeed.Message(id: reply, role: "assistant", text: String(whole.prefix(40_000)), textCut: true,
                                   createdAt: Date())
        vm.conversation.store.apply(.snapshot(feed(conv, messages: [cut])))
        vm.feedChanged()
        await vm.fullTextLoad?.value
        XCTAssertEqual(vm.messages.first?.text.count, 41_000)
        XCTAssertEqual(vm.messages.first?.textCut, false)
    }

    /// Entering the tab resumes a chat the list shows as answering, whatever the time; else the landing.
    func testEnterTabResumesAnAnsweringChat() {
        let old = Date().addingTimeInterval(-10 * 3600)
        vm.list.store.apply(.snapshot(ChatList(conversations: [
            ChatList.Conversation(id: 3, title: "Running", updatedAt: old, state: .answering),
            ChatList.Conversation(id: 4, title: "Idle", updatedAt: old, state: .read)
        ])))
        vm.enterTab(rememberedConversationID: 4, lastViewedAt: old, now: Date())
        XCTAssertTrue(vm.isOnLanding, "an idle chat outside the window gives the landing")
        vm.enterTab(rememberedConversationID: 3, lastViewedAt: old, now: Date())
        XCTAssertEqual(vm.conversationID, 3)
        XCTAssertFalse(vm.isOnLanding)
    }
}

/// The Chats panel's window state over the engine's list.
@MainActor
final class ChatPanelModelTests: XCTestCase {
    private var panel: ChatPanelModel!
    private var suite: String!
    private let now = Date()

    override func setUp() async throws {
        suite = "ChatPanelModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        panel = ChatPanelModel(list: ChatListModel(client: RecordingChatClient()), workspace: "/tmp/acme.db",
                               defaults: defaults)
        panel.now = { self.now }
        let acme = ChatList.Project(id: 1, name: "Acme")
        func chat(
            _ id: Int64,
            _ title: String,
            daysAgo: Double,
            pinned: Bool = false,
            project: ChatList.Project? = nil,
            state: ChatList.State = .read
        ) -> ChatList.Conversation {
            ChatList.Conversation(id: id, title: title, pinned: pinned, updatedAt: now.addingTimeInterval(-daysAgo * 86_400),
                                  project: project, state: state)
        }
        panel.list.store.apply(.snapshot(ChatList(conversations: [
            chat(1, "pinned", daysAgo: 40, pinned: true),
            chat(2, "fresh", daysAgo: 0.1, project: acme),
            chat(3, "answering", daysAgo: 0.2, state: .answering),
            chat(4, "old", daysAgo: 30)
        ], projects: [acme])))
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testSectionsFoldTheOlderGroupAndTheLevelFilters() {
        XCTAssertEqual(panel.sections.map(\.kind), [.pinned, .recent, .older])
        XCTAssertEqual(panel.visibleRowIDs, [1, 2, 3], "the folded group shows nothing until its chat is on screen")
        panel.selectedConversationID = 4
        XCTAssertEqual(panel.visibleRowIDs, [1, 2, 3, 4])
        panel.olderExpanded = true
        panel.selectedConversationID = nil
        XCTAssertEqual(panel.visibleRowIDs, [1, 2, 3, 4])

        var levels: [ChatPanelLevel] = []
        panel.onLevelChanged = { levels.append($0) }
        panel.selectLevel(.project(1))
        XCTAssertEqual(panel.rows.map(\.id), [2])
        XCTAssertEqual(levels, [.project(1)])
        XCTAssertFalse(panel.olderExpanded, "remembered per level")
    }

    func testTheCursorStartsOnTheChatOnScreenAndMovesWithoutOpening() {
        panel.selectedConversationID = 3
        panel.enterPanelKeyboard()
        XCTAssertEqual(panel.panelCursor, 3)
        panel.movePanelCursor(-1)
        XCTAssertEqual(panel.panelCursor, 2)
        XCTAssertEqual(panel.selectedConversationID, 3, "moving opens nothing")
        XCTAssertEqual(panel.rowID(atShortcut: 1), 1)
        XCTAssertNil(panel.rowID(atShortcut: 9))
    }

    func testQuickDeleteHasUndoAndSparesAnAnsweringChat() {
        XCTAssertFalse(panel.deleteWithUndo(3), "an answering chat asks first")
        panel.panelCursor = 2
        XCTAssertTrue(panel.deleteWithUndo(2))
        XCTAssertEqual(panel.panelCursor, 3, "the cursor moves to the neighbour")
        XCTAssertFalse(panel.rows.contains { $0.id == 2 })
        XCTAssertEqual(panel.pendingDeleteToast, "Chat deleted: “fresh”")
        XCTAssertEqual(panel.switcherRows.first { $0.id == 1 }?.lastActivity, .distantPast,
                       "a chat in the Undo window counts for nothing")
        XCTAssertEqual(panel.undoPendingDelete(), 2)
        XCTAssertTrue(panel.rows.contains { $0.id == 2 })
        XCTAssertNil(panel.pendingDeleteToast)
    }

    func testAGoneProjectFallsBackToAllChats() {
        panel.selectLevel(.project(77))
        XCTAssertEqual(panel.resolvedLevel, .all)
        XCTAssertEqual(panel.rows.count, 4)
    }
}
