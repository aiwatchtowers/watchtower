import ChatUI
import ChatWire
import GRDB
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// CHAT-01 across a kill (fix round 1): a send is kept in the hub's copy until its `chat_turn` is applied; a
/// relaunch gives back a send that never reached its turn or that the hub refused, and a lost echo gives the text
/// back after the patience.
@MainActor
final class ChatSendRecoveryTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var copy: ChatOfflineCopy!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        copy = try ChatOfflineCopy(path: nil)
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private var withdrawals: [String] = []
    /// What the outbox says when a send gives up: taken back, or the hub may have it.
    private var withdrawal = OutboxWithdrawal.withdrawn

    private func center(uploads: ChatUploads = .none) -> ChatsCenter {
        let sleeper: TickSleeper = sleeper
        return ChatsCenter(
            sender: recorder.sender, uploads: uploads, copy: copy,
            withdraw: { [weak self] id in
                self?.withdrawals.append(id)
                return self?.withdrawal ?? .onItsWay
            },
            now: { ChatFixture.now }, sleep: { try await sleeper.sleep($0) }
        )
    }

    private func queuedTurn(_ id: String, conversation: Int64, text: String) throws -> [String: QueuedChatAction] {
        [id: QueuedChatAction(kind: .chatTurn, params: try ChatTurnParams(conversationID: conversation, mode: .send, text: text).wireParams())]
    }

    private func applied(_ index: Int, _ kind: ActionKind, _ result: [String: JSONValue]) -> ActionRequestPayload {
        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(index), kind: kind, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        echo.result = result
        return echo
    }

    /// A conversation screen's composer over the center's client, the hub answering, with `text` (and `quote`) typed.
    private func composer(_ center: ChatsCenter, _ route: ChatRoute, text: String, quote: String? = nil) -> ChatComposerModel {
        center.setGate(ChatsGateModel(ChatFixture.inputs()))
        let (_, composer) = center.conversation(route)
        if let quote { composer.addQuote(quote) }
        composer.draft = text
        return composer
    }

    func testARelaunchBetweenChatNewAndChatTurnGivesTheDraftBack() async throws {
        let first = center(uploads: ChatUploads { _, _ in })
        first.setGate(ChatsGateModel(ChatFixture.inputs()))
        let (conversation, composer) = first.conversation(.new)
        XCTAssertNil(first.attach(data: Data("notes".utf8), fileName: "notes.md", conversation: 0))
        composer.draft = "Read this"
        _ = Task { await composer.send() }
        try await poll({ !((try? self.recorder.params(ChatNewParams.self)) ?? []).isEmpty }, "chat_new")
        XCTAssertEqual(try copy.outgoing().sends.first?.text, "Read this", "kept before chat_new goes")
        first.receiveApplied(applied(1, .chatNew, ["conversation_id": .integer(88)]))
        try await poll({ conversation.conversationID == 88 }, "created")
        XCTAssertEqual(try copy.outgoing().sends.first?.conversationID, 88, "the send is kept with its new chat")

        // The app is killed during the upload; the next launch reads the kept send.
        let second = center()
        second.apply(ChatsSnapshot())
        XCTAssertEqual(second.drafts.draft(88).text, "Read this")
        XCTAssertEqual(second.drafts.draft(88).notice, ChatSendCoordinator.couldNotSend)
        XCTAssertEqual(second.drafts.draft(88).attachments.map(\.name), ["notes.md"])
        XCTAssertTrue(try copy.outgoing().sends.isEmpty)
        // The conversation screen opens on it, the file among its pills.
        let (_, reopened) = second.conversation(ChatRoute(id: 88))
        XCTAssertEqual(reopened.draft, "Read this")
    }

    func testARefusalAfterARelaunchGivesTheTextBackWithTheReason() async throws {
        let first = center()
        let composer = composer(first, ChatRoute(id: 7), text: "When?", quote: "the SSO deadline")
        _ = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let turn = RecordingChatSender.actionID(1)
        try await poll({ (try? self.copy.outgoing().sends.first?.turnActionID) == turn }, "turn kept")

        let second = center()
        let composed = ChatQuoteReply.compose(quotes: [ChatQuoteDraft(quote: "the SSO deadline", comment: "")], typed: "When?") ?? ""
        var queued = ChatsSnapshot()
        queued.queued = try queuedTurn(turn, conversation: 7, text: composed)
        second.apply(queued)
        XCTAssertEqual(second.sending.pending[7]?.text, composed)
        XCTAssertEqual(second.drafts.draft(7).text, "", "still on its way: nothing back yet")

        var refused = ChatsSnapshot()
        refused.failures = [turn: ChatActionFailure(reason: .conversationBusy, message: "This chat is busy.")]
        second.apply(refused)
        XCTAssertEqual(second.drafts.draft(7).text, "When?")
        XCTAssertEqual(second.drafts.draft(7).quotes.map(\.quote), ["the SSO deadline"])
        XCTAssertEqual(second.drafts.draft(7).notice, "This chat is busy.")
        let (_, reopened) = second.conversation(ChatRoute(id: 7))
        XCTAssertEqual(reopened.draft, "When?")
        XCTAssertEqual(reopened.quotes.map(\.quote), ["the SSO deadline"], "the quote comes back as a quote")
        XCTAssertNil(second.sending.pending[7])
        XCTAssertTrue(try copy.outgoing().sends.isEmpty)
    }

    func testATurnAppliedWhileTheAppWasDeadLeavesNothingBehind() async throws {
        let first = center()
        let composer = composer(first, ChatRoute(id: 7), text: "Hi")
        _ = Task { await composer.send() }
        try await poll({ (try? self.copy.outgoing().sends.first?.turnActionID) != nil }, "turn kept")
        let second = center()
        second.apply(ChatsSnapshot())
        XCTAssertEqual(second.drafts.draft(7).text, "", "gone from the outbox: applied, the feed has it")
        XCTAssertTrue(try copy.outgoing().sends.isEmpty)
    }

    /// A lost answer (no echo within the patience, the outbox took the turn back) goes again under the same client key
    /// (the hub hands it to the engine, which applies a key once); lost again, the composer waits for the chat to come
    /// back, then gives up with the text kept.
    func testALostEchoGivesTheTextBackAfterThePatience() async throws {
        let center = center()
        let composer = composer(center, ChatRoute(id: 7), text: "Hello")
        // On screen: the model hears the chat come back (or not) while a lost send waits.
        composer.conversation.start()
        defer { composer.conversation.stop() }
        try await poll({ (try? self.recorder.params(ChatFeedRequestParams.self).count) == 1 }, "the screen opened")
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        try await poll({ self.sleeper.requested.contains(ChatSendCoordinator.echoPatience) }, "patience")
        XCTAssertFalse(composer.canSend, "pending")
        sleeper.tick()
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 2 }, "sent again")
        let turns = try recorder.params(ChatTurnParams.self)
        XCTAssertEqual(turns[0].clientKey, turns[1].clientKey, "the same send, never a second turn")
        try await poll({ self.sleeper.requested.filter { $0 == ChatSendCoordinator.echoPatience }.count == 2 }, "second patience")
        sleeper.tick()
        try await poll({ self.sleeper.requested.contains(ChatConversationModel.reconnectPatience) }, "waits for the chat")
        sleeper.tick()
        await send.value
        XCTAssertEqual(composer.draft, "Hello", "the text never left the composer")
        let turnIDs = recorder.sent.enumerated().filter { $0.element.kind == .chatTurn }.map { RecordingChatSender.actionID($0.offset + 1) }
        XCTAssertEqual(withdrawals, turnIDs, "each turn is taken back first")
        XCTAssertEqual(composer.line, ChatConversationModel.unreachableSendLine)
        XCTAssertNil(center.sending.pending[7])
        XCTAssertTrue(try copy.outgoing().sends.isEmpty)
    }

    func testALateEchoTheOutboxCannotTakeBackIsHonoured() async throws {
        withdrawal = .onItsWay
        let center = center()
        let composer = composer(center, ChatRoute(id: 7), text: "Hello")
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        try await poll({ self.sleeper.requested.contains(ChatSendCoordinator.echoPatience) }, "patience")
        sleeper.tick()
        try await poll({ center.sending.pending[7]?.isStalled == true }, "stalled")
        XCTAssertEqual(composer.draft, "Hello", "the hub may have it: the send waits, the text stays")
        XCTAssertFalse(composer.canSend, "never sent twice")
        XCTAssertEqual(center.hold(7, composerSending: composer.isSending, host: .mac), "Waiting for your Mac…")
        // Opened again meanwhile, the screen's composer holds Send too.
        let (_, reopened) = center.conversation(ChatRoute(id: 7))
        reopened.draft = "Hello"
        reopened.hold = center.hold(7, composerSending: reopened.isSending, host: .mac)
        XCTAssertFalse(reopened.canSend)
        XCTAssertEqual(reopened.line, "Waiting for your Mac…")

        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(1), kind: .chatTurn, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        echo.result = ["user_message_id": .integer(41)]
        center.receiveApplied(echo)
        await send.value
        XCTAssertEqual(center.sending.pending[7]?.isApplied, true, "marked sent")
        XCTAssertNil(center.hold(7, composerSending: false, host: .mac))
        XCTAssertEqual(composer.draft, "")
        XCTAssertTrue(try copy.outgoing().sends.isEmpty)
    }

    func testRecoveryFindsAQueuedTurnTheKeptSendNeverHeardOf() async throws {
        try copy.saveOutgoing(ChatOutgoingSend(
            clientKey: "k1", conversationID: 7, mode: "send", messageID: nil, text: "Hi there", draftText: "Hi there", quotes: [],
            files: [], createdAt: ChatFixture.now
        ))
        withdrawal = .onItsWay
        let center = center()
        var snapshot = ChatsSnapshot()
        snapshot.queued = try queuedTurn("turn-9", conversation: 7, text: "Hi there")
        center.apply(snapshot)
        XCTAssertEqual(center.drafts.draft(7).text, "", "the outbox holds it: no Couldn't send")
        XCTAssertEqual(center.sending.pending[7]?.text, "Hi there")
        XCTAssertEqual(center.hold(7, composerSending: false, host: .mac), "Waiting for your Mac…", "shown, and Send held")
        XCTAssertEqual(try copy.outgoing().sends.first?.turnActionID, "turn-9")

        try await poll({ self.sleeper.requested.contains(ChatSendCoordinator.echoPatience) }, "patience")
        sleeper.tick()
        try await poll({ center.sending.pending[7]?.isStalled == true }, "stalled, not given back")
        var echo = ActionRequestPayload(id: "turn-9", kind: .chatTurn, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        center.receiveApplied(echo)
        XCTAssertNil(center.sending.pending[7])
        XCTAssertEqual(center.drafts.draft(7).text, "")
        XCTAssertTrue(try copy.outgoing().sends.isEmpty)
    }

    /// B1: a kept send that no longer decodes is dropped (by key, after a log line) and never stops the readable
    /// ones from coming back.
    func testAnUndecodableKeptSendIsDroppedAndTheRestRecovered() async throws {
        let path = NSTemporaryDirectory() + "chat-copy-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        copy = try ChatOfflineCopy(path: path)
        try copy.saveOutgoing(ChatOutgoingSend(
            clientKey: "good", conversationID: 7, mode: "send", messageID: nil, text: "Hi there", draftText: "Hi there", quotes: [],
            files: [], createdAt: ChatFixture.now
        ))
        let raw = try DatabaseQueue(path: path)
        try await raw.write { try $0.execute(sql: "INSERT INTO chat_outgoing (client_key, body) VALUES ('bad', x'00ff')") }
        let kept = try copy.outgoing()
        XCTAssertEqual(kept.sends.map(\.clientKey), ["good"])
        XCTAssertEqual(kept.undecodableKeys, ["bad"])

        let center = center()
        center.apply(ChatsSnapshot())
        XCTAssertEqual(center.drafts.draft(7).text, "Hi there", "the readable send comes back")
        let left = try await raw.read { try String.fetchAll($0, sql: "SELECT client_key FROM chat_outgoing") }
        XCTAssertFalse(left.contains("bad"), "the unreadable row is deleted")
    }

    /// B1: a copy whose kept sends cannot be read recovers nothing and deletes nothing.
    func testAKeptSendReadFailureDeletesNothing() async throws {
        let path = NSTemporaryDirectory() + "chat-copy-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        copy = try ChatOfflineCopy(path: path)
        try copy.saveOutgoing(ChatOutgoingSend(
            clientKey: "k1", conversationID: 7, mode: "send", messageID: nil, text: "Hi there", draftText: "Hi there", quotes: [],
            files: [], createdAt: ChatFixture.now
        ))
        let raw = try DatabaseQueue(path: path)
        try await raw.write { try $0.execute(sql: "ALTER TABLE chat_outgoing RENAME TO chat_outgoing_away") }
        XCTAssertThrowsError(try copy.outgoing())
        let center = center()
        center.apply(ChatsSnapshot())
        XCTAssertEqual(center.drafts.draft(7).text, "", "nothing recovered")
        try await raw.write { try $0.execute(sql: "ALTER TABLE chat_outgoing_away RENAME TO chat_outgoing") }
        XCTAssertEqual(try copy.outgoing().sends.map(\.clientKey), ["k1"], "the row waits for a launch that can read it")
    }

    /// n5: an applied chat_turn no send here waits for is not held once no send is in flight.
    func testEarlyEchoesArePrunedWhenASendEnds() async throws {
        let center = center()
        center.receiveApplied(applied(99, .chatTurn, [:]))
        XCTAssertEqual(center.sending.earlyEchoCount, 1)
        let composer = composer(center, ChatRoute(id: 7), text: "Hello")
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let turn = try XCTUnwrap(recorder.sent.firstIndex { $0.kind == .chatTurn }) + 1
        center.receiveApplied(applied(turn, .chatTurn, ["user_message_id": .integer(5)]))
        await send.value
        try await poll({ center.sending.earlyEchoCount == 0 }, "pruned when the send ended")
    }

    func testAnAppliedUploadDropsItsPlaintext() async throws {
        var uploaded: [ChatAttachmentUploadPayload] = []
        let center = center(uploads: ChatUploads { payload, _ in uploaded.append(payload) })
        let composer = composer(center, ChatRoute(id: 7), text: "Read")
        XCTAssertNil(center.attach(data: Data("notes".utf8), fileName: "notes.md", conversation: 7))
        let file = try XCTUnwrap(center.drafts.draft(7).attachments.first?.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        _ = Task { await composer.send() }
        try await poll({ uploaded.count == 1 }, "uploaded")
        var echo = try XCTUnwrap(uploaded.first)
        echo.status = .applied
        echo.attachmentID = 5
        center.sending.receiveUpload(echo)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.attachmentIDs, [5])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the plaintext goes once the hub holds the file")
    }
}

/// The prefetch asks the hub session whether the hub answers (fix round 1), needs a fresh record to free its slot,
/// and steps again after its patience; the copy's writes land in order.
@MainActor
final class ChatPrefetchReachabilityTests: XCTestCase {
    func testThePrefetchFollowsTheSessionsReachabilityWithNoScreen() async throws {
        let recorder = RecordingChatSender()
        let center = ChatsCenter(sender: recorder.sender, now: { ChatFixture.now }, sleep: { _ in try await Task.sleep(for: .seconds(86_400)) })
        var reachable = false
        center.setReachability { reachable }
        center.apply(ChatsSnapshot(list: ChatList(conversations: [ChatFixture.conversation(1), ChatFixture.conversation(2, ago: 120)])))
        await Task.yield()
        XCTAssertTrue(recorder.sent.isEmpty, "the hub sleeps: nothing")
        reachable = true
        center.stepPrefetch()
        try await poll({ recorder.sent.count == 1 }, "prefetch")
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self).first?.purpose, .prefetch)
    }

    func testAHeldRecordDoesNotFreeTheSlotAFreshOneDoes() async throws {
        let recorder = RecordingChatSender()
        let sleeper = TickSleeper()
        defer { sleeper.cancelAll() }
        let center = ChatsCenter(sender: recorder.sender, now: { ChatFixture.now }, sleep: { try await sleeper.sleep($0) })
        let list = ChatList(conversations: [ChatFixture.conversation(1), ChatFixture.conversation(2, ago: 120)])
        var snapshot = ChatsSnapshot(list: list)
        snapshot.feeds[1] = ChatFixture.entry(ChatFixture.feed(1, messages: [ChatFixture.message(1)]))
        center.apply(snapshot)
        center.setReachability { true }
        try await poll({ recorder.sent.count == 1 }, "first prefetch")
        XCTAssertEqual(center.prefetch.inFlight?.id, 1)
        snapshot.searches = ["x": ChatSearch(query: "x", hits: [])]
        center.apply(snapshot)
        XCTAssertEqual(center.prefetch.inFlight?.id, 1, "the record it already held is no answer")
        snapshot.feeds[1] = ChatFixture.entry(ChatFixture.feed(1, messages: [ChatFixture.message(1), ChatFixture.message(2)]))
        center.apply(snapshot)
        try await poll({ recorder.sent.count == 2 }, "fresh record: the next one goes")
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self).last?.conversationID, 2)

        try await poll({ sleeper.requested.filter { $0 == .seconds(ChatPrefetcher.patience) }.count == 2 }, "patience")
        sleeper.tick()
        try await poll({ center.prefetch.inFlight == nil }, "the unanswered one stops holding the line")
    }

    func testCopyWritesLandInOrder() async throws {
        let copy = try ChatOfflineCopy(path: nil)
        let center = ChatsCenter(sender: RecordingChatSender().sender, copy: copy)
        for count in 1...5 {
            let json: [String: Any] = [
                "conversation": ["id": 1, "title": "T"],
                "messages": (1...count).map { ["id": $0, "role": "assistant", "text": "m\($0)", "created_at": 1_800_000_000] }
            ]
            let payload = try JSONSerialization.data(withJSONObject: json)
            var snapshot = center.snapshot
            snapshot.feeds[1] = ChatFeedEntry(feed: try ChatFeed.decode(payload: payload), payload: payload)
            center.apply(snapshot)
        }
        await center.copyWritesDone()
        XCTAssertEqual(try copy.held(conversationID: 1)?.feed?.messages.count, 5, "the newest snapshot is the one kept")
    }
}

/// Fix round 1's small screen rules.
final class ChatScreenTextTests: XCTestCase {
    func testTheNavChipWhileTheHubIsAway() {
        XCTAssertNil(ChatNavChip(mac: .online, relayUnreachable: false))
        XCTAssertEqual(ChatNavChip(mac: .asleep(lastSeen: ChatFixture.now), relayUnreachable: false)?.word, "asleep")
        XCTAssertEqual(ChatNavChip(mac: .offline, relayUnreachable: false)?.word, "offline")
        XCTAssertEqual(ChatNavChip(mac: .online, relayUnreachable: true)?.word, "offline")
    }
}
