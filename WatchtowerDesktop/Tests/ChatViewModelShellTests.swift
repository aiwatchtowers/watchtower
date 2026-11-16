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

    /// The connection is down: every send is a lost answer (`ChatConnectionError`).
    var disconnected = false
    struct Dropped: ChatConnectionError {}
    private var watchers: [AsyncStream<ChatReachability>.Continuation] = []
    private var sendWaiters: [(count: Int, match: @Sendable (ChatOperation) -> Bool, done: CheckedContinuation<Void, Never>)] = []

    /// Returns once `count` sent operations match `match` (a send made by a task the test cannot await).
    func sent(_ count: Int, matching match: @escaping @Sendable (ChatOperation) -> Bool) async {
        await withCheckedContinuation { done in
            let reached = lock.withLock { () -> Bool in
                if recorded.filter(match).count >= count { return true }
                sendWaiters.append((count, match, done))
                return false
            }
            if reached { done.resume() }
        }
    }

    /// Reports `state` to every reachability stream (a reconnect: `.connected`).
    func report(_ state: ChatReachability) {
        lock.withLock { watchers }.forEach { $0.yield(state) }
    }

    var turns: [ChatTurnRequest] {
        ops.compactMap { op in
            guard case .turn(let request) = op else { return nil }
            return request
        }
    }

    func send(_ op: ChatOperation) async throws -> ChatEcho {
        let (down, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            recorded.append(op)
            let recorded = recorded
            let ready = sendWaiters.filter { recorded.filter($0.match).count >= $0.count }.map(\.done)
            sendWaiters.removeAll { recorded.filter($0.match).count >= $0.count }
            return (disconnected, ready)
        }
        ready.forEach { $0.resume() }
        if down { throw Dropped() }
        return answer(op) ?? .applied(.none)
    }

    func feed(_ conversation: Int64) -> AsyncStream<ChatFeedUpdate> { AsyncStream { _ in } }
    func list() -> AsyncStream<ChatListUpdate> { AsyncStream { _ in } }
    var reachability: AsyncStream<ChatReachability> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChatReachability.self)
        lock.withLock { watchers.append(continuation) }
        return stream
    }
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

/// The Mac's behaviours kept through the move (T8 review I1, I3, I4).
@MainActor
final class ChatViewModelKeptBehaviourTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var client: RecordingChatClient!
    private var vm: ChatViewModel!
    private var suite: String!

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
        suite = "ChatViewModelKeptBehaviourTests.\(UUID().uuidString)"
        vm = ChatViewModel(client: client, dbPool: pool, defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    override func tearDown() {
        vm.conversation.stop()
        UserDefaults().removePersistentDomain(forName: suite)
        TestDatabase.cleanup(path: path)
    }

    private static let isDiscard: @Sendable (ChatOperation) -> Bool = { op in
        if case .manage(_, .discard, _, _) = op { return true }
        return false
    }

    private func discards() -> [Int64] {
        client.ops.compactMap { op in
            guard case let .manage(id, .discard, _, _) = op else { return nil }
            return id
        }
    }

    private func warms() -> [Int64] {
        client.ops.compactMap { op in
            guard case let .warm(id, _) = op else { return nil }
            return id
        }
    }

    /// I1: a connector call of a chat that is not on screen is still held while its turn runs (the list names it),
    /// so the Inbox strip keeps Approve on; another turn's call is not.
    func testACallOfAChatNotOnScreenIsHeldWhileItsTurnRuns() throws {
        vm.select(conversationID: 1)
        vm.list.store.apply(.snapshot(ChatList(conversations: [
            ChatList.Conversation(id: 5, title: "Slack draft", updatedAt: Date(), state: .waiting, leaseOwner: "hub",
                                  turnID: "turn-7")
        ])))
        func action(_ id: Int64, turn: String) -> AgentAction {
            AgentAction(row: ["id": id, "tool": "send_slack_message", "conversation_id": 5, "turn_id": turn,
                              "status": "pending"])
        }
        let held = action(1, turn: "turn-7")
        let older = action(2, turn: "turn-6")
        XCTAssertTrue(vm.holdsSessionCall(held))
        XCTAssertFalse(vm.holdsSessionCall(older))
        let list = try XCTUnwrap(vm.list.store.list)
        XCTAssertEqual(AppState.runningTurns(in: list), [5: "turn-7"])
    }

    /// I4a: the landing's first keystroke makes its chat (with the pill's routing) and warms its session; leaving
    /// the landing unsent discards the draft; a sent draft is never discarded.
    func testTheLandingWarmsItsChatOnTheFirstKeystrokeAndDiscardsItIfLeft() async throws {
        vm.showLanding(inProject: 3)
        vm.switchProvider(.codex)
        vm.composer.draft = "S"
        await vm.draftStarted()
        await vm.engineCallsSettled()
        guard case let .new(projectID, routing)? = client.ops.first else { return XCTFail("no chat_new") }
        XCTAssertEqual(projectID, 3)
        XCTAssertEqual(routing, ChatRouting(mode: "pinned", provider: "codex", model: nil))
        XCTAssertEqual(warms(), [9])
        XCTAssertEqual(vm.landingDraftID, 9)
        XCTAssertTrue(vm.isOnLanding, "the landing stays until the first send")

        vm.select(conversationID: 4)
        await vm.engineCallsSettled()
        XCTAssertEqual(discards(), [9])
        XCTAssertEqual(warms(), [9, 4], "opening a chat warms its session too")
        XCTAssertNil(vm.landingDraftID)

        vm.showLanding()
        vm.composer.draft = "next"
        client.answer = { op in
            switch op {
            case .new: .applied(.conversation(id: 10))
            case .turn: .applied(.turn(ChatTurnStarted(userMessageID: 1, assistantMessageID: 2, turnID: "t2")))
            default: nil
            }
        }
        await vm.draftStarted()
        await vm.sendDraft()
        XCTAssertNil(vm.landingDraftID, "sent: no longer a draft")
        vm.select(conversationID: 4)
        await vm.engineCallsSettled()
        XCTAssertEqual(discards(), [9], "a sent chat is never discarded")
    }

    /// I4a: a draft abandoned by quitting is discarded at the next start (the engine deletes it only if untouched).
    func testAnAbandonedDraftIsDiscardedAtTheNextStart() async throws {
        vm.showLanding()
        await vm.draftStarted()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let next = ChatViewModel(client: client, dbPool: pool, defaults: defaults)
        next.start()
        await next.engineCallsSettled()
        XCTAssertEqual(discards(), [9])
        next.conversation.stop()
    }

    /// A landing draft is never left behind: a discard the lost connection did not deliver stays listed and goes on
    /// the next `.connected`; its id leaves the list only once the engine answered.
    func testADiscardWhileDisconnectedIsRetriedAfterTheConnect() async throws {
        vm.start()
        vm.showLanding()
        await vm.draftStarted()
        client.disconnected = true
        vm.select(conversationID: 4)
        await vm.engineCallsSettled()
        XCTAssertEqual(vm.draftsToDiscard, [9], "kept while the engine has not answered")
        XCTAssertEqual(discards(), [9], "tried once")

        client.disconnected = false
        client.report(.connected)
        await client.sent(2, matching: Self.isDiscard)
        // Awaits the reconnect's own pass (already under way), then finds nothing left to send.
        await vm.flushDiscards()
        XCTAssertEqual(discards(), [9, 9], "sent again on the reconnect")
        XCTAssertTrue(vm.draftsToDiscard.isEmpty, "answered: off the list")
    }

    /// A crash (or quit) leaves the landing's draft id stored: the next start discards it first, when the engine
    /// answers — also when the socket connects only after the start. A chat that got a message in the meantime is
    /// kept by the engine (`TestChatengine_DiscardDeletesOnlyAnUntouchedDraft`: one atomic DELETE … NOT EXISTS).
    func testACrashLeftoverDraftIsDiscardedAtTheNextStart() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        vm.showLanding()
        await vm.draftStarted()
        XCTAssertEqual(vm.landingDraftID, 9, "stored: the app now crashes")

        client.disconnected = true
        let next = ChatViewModel(client: client, dbPool: pool, defaults: defaults)
        next.start()
        await next.engineCallsSettled()
        XCTAssertEqual(next.draftsToDiscard, [9], "not connected yet: kept")
        client.disconnected = false
        client.report(.connected)
        await client.sent(2, matching: Self.isDiscard)
        await next.flushDiscards()
        XCTAssertEqual(discards(), [9, 9], "tried at the start, sent again on the connect")
        XCTAssertTrue(next.draftsToDiscard.isEmpty, "answered: off the list")
        next.conversation.stop()
    }

    /// I4c: a search hit opens its chat and brings its message into view, loading earlier pages until it is there.
    func testASearchHitScrollsToItsMessage() async throws {
        let hit = ChatSearch.Hit(conversationID: 4, title: "Plan", snippet: "x", messageID: 2, date: Date())
        vm.open(hit)
        XCTAssertEqual(vm.conversation.focusMessageID, 2)
        let late = ChatFeed.Message(id: 90, role: "assistant", text: "late", createdAt: Date())
        client.answer = { op in
            guard case .page = op else { return nil }
            return .applied(.page(ChatPage(messages: [ChatFeed.Message(id: 2, role: "user", text: "the hit", createdAt: Date())])))
        }
        vm.conversation.store.apply(.snapshot(ChatFeed(conversation: ChatFeed.Conversation(id: 4, title: "Plan"),
                                                       messages: [late], hasMore: true)))
        // What the thread view runs whenever the loaded messages change.
        await vm.conversation.followFocus()
        XCTAssertTrue(vm.messages.contains { $0.id == 2 }, "the earlier page holding the hit is loaded")
        XCTAssertEqual(vm.conversation.feedContext(composer: vm.composer, partActions: ChatPartActions()).focusMessageID, 2,
                       "the feed scrolls to it")
    }

    /// I3: "Review actions" shows the reply's turn's actions under it; a proposal of a turn with no stored message
    /// is listed as from an interrupted turn; a pending card of the running turn is the awaited one.
    func testReviewUnattachedAndAwaitedCards() async throws {
        let (conv, reply, orphan, mine) = try await pool.write { d -> (Int64, Int64, Int64, Int64) in
            let conv = try TestDatabase.insertChatConversation(d, title: "Plan")
            let reply = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "a",
                                                           status: "error", turnID: "turn-1")
            let mine = try TestDatabase.insertAgentAction(d, conversationID: conv, turnID: "turn-1")
            let orphan = try TestDatabase.insertAgentAction(d, conversationID: conv, turnID: "turn-gone")
            return (conv, reply, orphan, mine)
        }
        vm.select(conversationID: conv)
        vm.actionFeed.refresh()
        vm.feedChanged()
        await vm.engineCallsSettled()
        XCTAssertEqual(vm.unattachedActions.map(\.id), [orphan])

        await vm.reviewActions(messageID: reply)
        XCTAssertEqual(vm.reviewedMessageID, reply)
        XCTAssertEqual(vm.reviewedActionIDs, [mine])
        XCTAssertEqual(vm.conversation.focusMessageID, reply)

        vm.conversation.store.apply(.snapshot(ChatFeed(
            conversation: ChatFeed.Conversation(id: conv, title: "Plan", lease: ChatFeed.Lease(owner: "hub", turnID: "turn-gone")),
            messages: [])))
        let pending = try XCTUnwrap(vm.actionFeed.rows.first { $0.id == orphan })
        XCTAssertTrue(vm.isAwaited(pending), "the running turn waits on its pending card")
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
