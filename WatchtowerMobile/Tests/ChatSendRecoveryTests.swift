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

    private func center(uploads: ChatUploads = .none) -> ChatsCenter {
        let sleeper: TickSleeper = sleeper
        return ChatsCenter(sender: recorder.sender, uploads: uploads, copy: copy, now: { ChatFixture.now }, sleep: { try await sleeper.sleep($0) })
    }

    private func applied(_ index: Int, _ kind: ActionKind, _ result: [String: JSONValue]) -> ActionRequestPayload {
        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(index), kind: kind, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        echo.result = result
        return echo
    }

    func testARelaunchBetweenChatNewAndChatTurnGivesTheDraftBack() async throws {
        let first = center(uploads: ChatUploads { _, _ in })
        let model = first.conversation(.new, ticks: ChatTicks().stream)
        model.appear(online: true)
        model.attach(data: Data("notes".utf8), fileName: "notes.md")
        model.setText("Read this")
        model.send(list: nil)
        try await poll({ !((try? self.recorder.params(ChatNewParams.self)) ?? []).isEmpty }, "chat_new")
        first.receiveApplied(applied(1, .chatNew, ["conversation_id": .integer(88)]))
        try await poll({ model.conversationID == 88 }, "created")
        XCTAssertEqual(try copy.outgoing().first?.conversationID, 88, "the send is kept with its new chat")

        // The app is killed during the upload; the next launch reads the kept send.
        let second = center()
        second.apply(ChatsSnapshot())
        XCTAssertEqual(second.drafts.draft(88).text, "Read this")
        XCTAssertEqual(second.drafts.draft(88).notice, ChatSendCoordinator.couldNotSend)
        XCTAssertEqual(second.drafts.draft(88).attachments.map(\.name), ["notes.md"])
        XCTAssertTrue(try copy.outgoing().isEmpty)
    }

    func testARefusalAfterARelaunchGivesTheTextBackWithTheReason() async throws {
        let first = center()
        let model = first.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.addQuote("the SSO deadline")
        model.setText("When?")
        model.send(list: nil)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let turn = RecordingChatSender.actionID(2)
        try await poll({ (try? self.copy.outgoing().first?.turnActionID) == turn }, "turn kept")

        let second = center()
        var queued = ChatsSnapshot()
        queued.queued = [turn]
        second.apply(queued)
        let composed = ChatQuoteReply.compose(quotes: [ChatQuoteDraft(quote: "the SSO deadline", comment: "")], typed: "When?")
        XCTAssertEqual(second.sending.pending[7]?.text, composed)
        XCTAssertEqual(second.drafts.draft(7).text, "", "still on its way: nothing back yet")

        var refused = ChatsSnapshot()
        refused.failures = [turn: ChatActionFailure(reason: .conversationBusy, message: "This chat is busy.")]
        second.apply(refused)
        XCTAssertEqual(second.drafts.draft(7).text, "When?")
        XCTAssertEqual(second.drafts.draft(7).quotes.map(\.quote), ["the SSO deadline"])
        XCTAssertEqual(second.drafts.draft(7).notice, "This chat is busy.")
        XCTAssertNil(second.sending.pending[7])
        XCTAssertTrue(try copy.outgoing().isEmpty)
    }

    func testATurnAppliedWhileTheAppWasDeadLeavesNothingBehind() async throws {
        let first = center()
        let model = first.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.setText("Hi")
        model.send(list: nil)
        try await poll({ (try? self.copy.outgoing().first?.turnActionID) != nil }, "turn kept")
        let second = center()
        second.apply(ChatsSnapshot())
        XCTAssertEqual(second.drafts.draft(7).text, "", "gone from the outbox: applied, the feed has it")
        XCTAssertTrue(try copy.outgoing().isEmpty)
    }

    func testALostEchoGivesTheTextBackAfterThePatience() async throws {
        let center = center()
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.setText("Hello")
        model.send(list: nil)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        try await poll({ self.sleeper.requested.contains(ChatSendCoordinator.echoPatience) }, "patience")
        XCTAssertEqual(model.composer(list: nil).canSend, false, "pending")
        sleeper.tick()
        try await poll({ model.draft.text == "Hello" }, "text back")
        XCTAssertEqual(model.draft.notice, ChatSendCoordinator.couldNotSend)
        XCTAssertNil(center.sending.pending[7])
        XCTAssertTrue(try copy.outgoing().isEmpty)
    }

    func testAnAppliedUploadDropsItsPlaintext() async throws {
        var uploaded: [ChatAttachmentUploadPayload] = []
        let center = center(uploads: ChatUploads { payload, _ in uploaded.append(payload) })
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.attach(data: Data("notes".utf8), fileName: "notes.md")
        let file = try XCTUnwrap(model.draft.attachments.first?.file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        model.setText("Read")
        model.send(list: nil)
        try await poll({ uploaded.count == 1 }, "uploaded")
        var echo = try XCTUnwrap(uploaded.first)
        echo.status = .applied
        echo.attachmentID = 5
        center.sending.receiveUpload(echo)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn")
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
    func testThePickerShowsTheAnswerAsRead() {
        let text = """
            #### Q3 roadmap
            - Billing **v2** is on track.

            :::artifact key="r" kind="email" title="Reply"
            Hello
            :::
            Two items: the `export` API.
            """
        XCTAssertEqual(ChatFeedItems.displayText(text), "Q3 roadmap\n\n• Billing v2 is on track.\n\nTwo items: the export API.")
    }

    func testTheNavChipWhileTheHubIsAway() {
        XCTAssertNil(ChatNavChip(mac: .online, relayUnreachable: false))
        XCTAssertEqual(ChatNavChip(mac: .asleep(lastSeen: ChatFixture.now), relayUnreachable: false)?.word, "asleep")
        XCTAssertEqual(ChatNavChip(mac: .offline, relayUnreachable: false)?.word, "offline")
        XCTAssertEqual(ChatNavChip(mac: .online, relayUnreachable: true)?.word, "offline")
    }
}
