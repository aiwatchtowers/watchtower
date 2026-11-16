import ChatUI
import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's `ChatClient` (unified chat spec §6.3): reachability from the Chats tab's gate, feeds from the relay's
/// `chat_feed` records and the offline copy, turns through `ChatSendCoordinator` (CHAT-01's phone half), the pickers
/// over their relay kinds, and the Mac-only operations refused.
@MainActor
final class RelayChatClientTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func center(copy: ChatOfflineCopy? = nil) -> ChatsCenter {
        let sleeper: TickSleeper = sleeper
        return ChatsCenter(sender: recorder.sender, copy: copy, now: { ChatFixture.now }, sleep: { try await sleeper.sleep($0) })
    }

    private static let ready = ChatsGateModel(ChatFixture.inputs())

    private func applied(_ index: Int, _ kind: ActionKind, _ result: [String: JSONValue]) -> ActionRequestPayload {
        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(index), kind: kind, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        echo.result = result
        return echo
    }

    /// A `chat_feed` payload as the hub publishes it.
    private static func feedPayload(_ conversation: Int64, texts: [String]) throws -> Data {
        let json: [String: Any] = [
            "conversation": ["id": conversation, "title": "Q3 roadmap summary"],
            "messages": texts.enumerated().map { ["id": $0.offset + 1, "role": "assistant", "text": $0.element, "created_at": 1_800_000_000] }
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    private static func entry(_ conversation: Int64, texts: [String]) throws -> ChatFeedEntry {
        let payload = try feedPayload(conversation, texts: texts)
        return ChatFeedEntry(feed: try ChatFeed.decode(payload: payload), payload: payload)
    }

    /// Feeds a client's stream into a `ChatFeedStore`, as `ChatConversationModel` does.
    private func watch(_ client: RelayChatClient, _ conversation: Int64) -> (ChatFeedStore, Task<Void, Never>) {
        let store = ChatFeedStore()
        let updates = client.feed(conversation)
        let task = Task { @MainActor in
            for await update in updates { store.apply(update) }
        }
        return (store, task)
    }

    func testRelayClientMapsGateToReachability() async throws {
        let notAllowed = ChatsGateModel(ChatFixture.inputs(grant: ChatFixture.grant(chat: false)))
        let needsRelay = ChatsGateModel(ChatFixture.inputs(
            heartbeat: ChatFixture.heartbeat(chat: "off", reason: .notRelay), route: .cloudKit(.private)
        ))
        let offline = ChatsGateModel(ChatFixture.inputs(mac: .offline))
        XCTAssertEqual(notAllowed.state, .notAllowed)
        XCTAssertEqual(needsRelay.state, .needsRelay)
        XCTAssertEqual(offline.state, .offline)
        // The gate's copy, unchanged.
        XCTAssertEqual(RelayChatClient.reachability(for: notAllowed), .offline(reason: ChatsGateModel.notAllowedTitle))
        XCTAssertEqual(RelayChatClient.reachability(for: needsRelay), .offline(reason: ChatsGateModel.relayTitle))
        XCTAssertEqual(RelayChatClient.reachability(for: offline), .offline(reason: ChatText.offline(.mac)))
        XCTAssertEqual(offline.banner, ChatText.offline(.mac))
        XCTAssertEqual(RelayChatClient.reachability(for: Self.ready), .connected)

        // The stream starts with the current state and follows the gate.
        let client = center().client
        client.setGate(notAllowed)
        var states = client.reachability.makeAsyncIterator()
        let first = await states.next()
        XCTAssertEqual(first, .offline(reason: ChatsGateModel.notAllowedTitle))
        client.setGate(Self.ready)
        let second = await states.next()
        XCTAssertEqual(second, .connected)
        // The shared state line shows the gate's words above the composer.
        XCTAssertEqual(ChatStateLine.content(for: .offline(reason: ChatsGateModel.notAllowedTitle))?.text, "Chat is off for this phone")
    }

    func testRelayClientSnapshotsFeedIntoStore() async throws {
        let center = center()
        let client = center.client
        client.setGate(Self.ready)
        let (store, task) = watch(client, 7)
        defer { task.cancel() }
        try await poll({ (try? self.recorder.params(ChatFeedRequestParams.self).count) == 1 }, "open request")
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self).first, ChatFeedRequestParams(conversationID: 7, purpose: .open))

        let first = try Self.entry(7, texts: ["Working…"])
        var snapshot = center.snapshot
        snapshot.feeds[7] = first
        center.apply(snapshot)
        try await poll({ store.feed == first.feed }, "the record as a snapshot")
        let second = try Self.entry(7, texts: ["Billing v2 is on track."])
        snapshot.feeds[7] = second
        center.apply(snapshot)
        try await poll({ store.feed == second.feed }, "every record replaces the feed whole")

        // The hub watches a feed for a while: the request repeats while the screen shows it.
        try await poll({ self.sleeper.requested.contains(RelayChatClient.repeatInterval) }, "repeat")
        sleeper.tick()
        try await poll({ (try? self.recorder.params(ChatFeedRequestParams.self).count) == 2 }, "repeated")
    }

    func testOfflineCopyPagesFeedStoreAsSnapshot() async throws {
        let copy = try ChatOfflineCopy(path: nil)
        // One chat the owner opened, one the prefetch saved (the center writes every new record into the copy).
        let opened = try Self.feedPayload(3, texts: ["Opened before"])
        try copy.saveFeed(conversationID: 3, payload: opened)
        let writer = center(copy: copy)
        var prefetched = writer.snapshot
        prefetched.feeds[4] = try Self.entry(4, texts: ["Prefetched"])
        writer.apply(prefetched)
        await writer.copyWritesDone()

        let center = center(copy: copy)
        let client = center.client
        client.setGate(ChatsGateModel(ChatFixture.inputs(mac: .asleep(lastSeen: ChatFixture.now))))
        for (conversation, payload) in [(Int64(3), opened), (4, try XCTUnwrap(prefetched.feeds[4]?.payload))] {
            let (store, task) = watch(client, conversation)
            defer { task.cancel() }
            let stored = try ChatFeed.decode(payload: payload)
            try await poll({ store.feed != nil }, "the held copy")
            XCTAssertEqual(store.feed, stored)
            XCTAssertFalse(store.isStale)
            if conversation == 3 {
                // Back online, the relay's record replaces it.
                let live = try Self.entry(3, texts: ["Opened before", "Live now"])
                var snapshot = center.snapshot
                snapshot.feeds[3] = live
                center.apply(snapshot)
                try await poll({ store.feed == live.feed }, "the relay record replaces the copy")
            }
        }
        XCTAssertFalse(try recorder.params(ChatFeedRequestParams.self).contains { $0.purpose == .open }, "nothing asked while away")
    }

    func testRelaySendKeepsOutgoingUntilEcho() async throws {
        let copy = try ChatOfflineCopy(path: nil)
        let center = center(copy: copy)
        let client = center.client
        client.setGate(Self.ready)
        let conversation = ChatConversationModel(client: client, conversationID: 7)
        let composer = ChatComposerModel(conversation: conversation)
        composer.draft = "Summarise the Q3 roadmap"
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let turn = try XCTUnwrap(try recorder.params(ChatTurnParams.self).first)
        XCTAssertEqual(turn.conversationID, 7)
        XCTAssertEqual(turn.text, "Summarise the Q3 roadmap")
        // CHAT-01, the phone's half: the send is kept in the hub's copy and the text stays in the composer.
        XCTAssertEqual(try copy.outgoing().sends.map(\.text), ["Summarise the Q3 roadmap"])
        XCTAssertEqual(composer.draft, "Summarise the Q3 roadmap")

        center.receiveApplied(applied(1, .chatTurn, [
            "user_message_id": .integer(40), "assistant_message_id": .integer(41), "turn_id": .string("t-1")
        ]))
        await send.value
        XCTAssertEqual(composer.draft, "", "applied: the composer empties")
        XCTAssertTrue(try copy.outgoing().sends.isEmpty, "applied: the kept send goes")
        XCTAssertEqual(conversation.runningTurnID, nil)
        XCTAssertEqual(center.sending.pending[7]?.userMessageID, 40, "the turn's own message settles it")
    }

    func testEntitySearchOverRelayEcho() async throws {
        let center = center()
        let client = center.client
        client.setGate(Self.ready)
        let search = Task { try await client.send(.entitySearch(query: "ali", kinds: ["person"])) }
        try await poll({ (try? self.recorder.params(ChatEntitySearchParams.self).count) == 1 }, "asked")
        XCTAssertEqual(try recorder.params(ChatEntitySearchParams.self).first, ChatEntitySearchParams(query: "ali", kinds: ["person"]))
        center.receiveApplied(applied(1, .chatEntitySearch, [
            "hits": .array([.object(["kind": .string("person"), "id": .string("U1"), "label": .string("Alice"), "detail": .string("acme")])])
        ]))
        let echo = try await search.value
        XCTAssertEqual(echo, .applied(.entities([ChatEntityHit(kind: "person", id: "U1", label: "Alice", detail: "acme")])))

        let skills = Task { try await client.send(.skillsList) }
        try await poll({ (try? self.recorder.params(ChatSkillsListParams.self).count) == 1 }, "skills asked")
        center.receiveApplied(applied(2, .chatSkillsList, [
            "skills": .array([.object(["name": .string("weekly-report"), "description": .string("The week")])])
        ]))
        let listed = try await skills.value
        XCTAssertEqual(listed, .applied(.skills([ChatSkill(name: "weekly-report", description: "The week")])))
    }

    func testProjectEditUnsupportedOnPhone() async throws {
        let client = center().client
        client.setGate(Self.ready)
        let macOnly: [ChatOperation] = [
            .project(ChatProjectRequest(op: .create, name: "acme")),
            .artifact(ChatArtifactRequest(op: .keep, key: "r", version: 1)),
            .attach(conversationID: 7, source: .path("/tmp/notes.md")),
            .manage(conversationID: 7, op: .move, title: nil, projectID: 2),
            .turn(ChatTurnRequest(conversationID: 7, mode: .continue, messageID: 3, text: "", clientKey: "k")),
            .shutdown
        ]
        for op in macOnly {
            let echo = try await client.send(op)
            XCTAssertEqual(echo, .refused(code: "unsupported", message: "This works in Watchtower on your Mac."), op.wireOp)
        }
        XCTAssertTrue(recorder.sent.isEmpty, "nothing reaches the hub")
        // A server hub is a tower, never "your Mac".
        client.setGate(Self.ready, host: .server(device: nil))
        let onTower = try await client.send(.shutdown)
        XCTAssertEqual(onTower, .refused(code: "unsupported", message: "This works in Watchtower on your tower."))
    }

    /// The relay refuses a watched chat's feed request `not_found` once it is deleted elsewhere: the feed is gone.
    func testFeedRequestRefusedNotFoundIsGone() async throws {
        let center = center()
        let client = center.client
        client.setGate(Self.ready)
        let (store, task) = watch(client, 7)
        defer { task.cancel() }
        var snapshot = center.snapshot
        snapshot.feeds[7] = try Self.entry(7, texts: ["Hi"])
        center.apply(snapshot)
        try await poll({ store.feed != nil }, "feed")
        try await poll({ (try? self.recorder.params(ChatFeedRequestParams.self).count) == 1 }, "open request")
        snapshot.feeds[7] = nil
        snapshot.failures = [RecordingChatSender.actionID(1): ChatActionFailure(reason: .notFound, message: "This chat no longer exists")]
        center.apply(snapshot)
        try await poll({ store.isGone }, "gone")
        XCTAssertNil(store.feed)
    }

    /// The list is the `chat_list` record, each one a snapshot, read by `ChatUI`'s list model.
    func testListSnapshotsIntoTheListModel() async throws {
        let center = center()
        center.apply(ChatsSnapshot(list: ChatFixture.list))
        let model = center.listModel
        model.start()
        defer { model.stop() }
        try await poll({ model.conversations.map(\.id) == [1] }, "the held list")
        center.apply(ChatsSnapshot(list: ChatList(conversations: [ChatFixture.conversation(1), ChatFixture.conversation(2)])))
        try await poll({ model.conversations.map(\.id) == [1, 2] }, "the next record")
    }

    /// Mockup 2g: an opened chat with no feed within the patience says the Mac did not answer; Retry asks again.
    func testAnOpenedChatWithNoFeedSaysTheMacDidNotAnswer() async throws {
        let center = center()
        let client = center.client
        client.setGate(Self.ready)
        let (_, task) = watch(client, 7)
        defer { task.cancel() }
        try await poll({ self.sleeper.requested.contains(RelayChatClient.recordPatience) }, "patience")
        sleeper.tick()
        try await poll({ client.unanswered.contains(7) }, "no answer")
        client.retryFeed(7)
        XCTAssertFalse(client.unanswered.contains(7))
        try await poll({ ((try? self.recorder.params(ChatFeedRequestParams.self).count) ?? 0) >= 2 }, "asked again")
        var snapshot = center.snapshot
        snapshot.feeds[7] = try Self.entry(7, texts: ["Hi"])
        center.apply(snapshot)
        try await poll({ self.sleeper.requested.filter { $0 == RelayChatClient.recordPatience }.count >= 2 }, "fresh patience")
        sleeper.tick()
        await Task.yield()
        XCTAssertFalse(client.unanswered.contains(7), "the feed came")
    }

    /// A search goes as the relay takes it: trimmed and cut at 200 characters.
    func testTheSearchQueryIsTrimmedAndCut() {
        XCTAssertEqual(RelayChatClient.searchQuery("  billing \n"), "billing")
        XCTAssertEqual(RelayChatClient.searchQuery(String(repeating: "я", count: 250)).unicodeScalars.count, 200)
    }

    /// Offline, nothing is queued (spec D3): every operation that needs the hub is refused with the gate's line.
    func testOfflineNothingIsQueued() async throws {
        let client = center().client
        client.setGate(ChatsGateModel(ChatFixture.inputs(mac: .offline)))
        let echo = try await client.send(.turn(ChatTurnRequest(conversationID: 7, mode: .send, text: "Hello", clientKey: "k")))
        XCTAssertEqual(echo, .refused(code: "unreachable", message: ChatText.offline(.mac)))
        XCTAssertTrue(recorder.sent.isEmpty)
    }
}
