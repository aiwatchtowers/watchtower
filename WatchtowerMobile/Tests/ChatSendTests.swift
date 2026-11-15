import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone half of CHAT-01 (spec §6.3): `chat_new` → uploads → `chat_turn`; the owner bubble stays pending
/// until `applied`; a refused echo (`conversation_busy`) puts the text back into the composer with the reason.
@MainActor
final class ChatSendTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func applied(_ index: Int, kind: ActionKind, result: [String: JSONValue]) -> ActionRequestPayload {
        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(index), kind: kind, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        echo.result = result
        return echo
    }

    private func pendingOwner(_ model: ChatConversationModel) -> ChatFeedItem.Owner? {
        for item in model.items(permissions: true, host: .mac).reversed() {
            if case let .owner(owner) = item { return owner }
        }
        return nil
    }

    func testTheOwnerBubbleStaysPendingUntilApplied() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.setText("Summarise the Q3 roadmap")
        model.send(list: nil)
        XCTAssertEqual(model.draft.text, "", "the composer empties at once")
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(pendingOwner(model)?.isPending, true)
        XCTAssertEqual(pendingOwner(model)?.text, "Summarise the Q3 roadmap")

        center.receiveApplied(applied(2, kind: .chatTurn, result: ["user_message_id": .integer(40), "turn_id": .string("t")]))
        try await poll({ self.pendingOwner(model)?.isPending == false }, "applied")
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: [ChatFixture.message(40, "user", "Summarise the Q3 roadmap")]))
        center.apply(snapshot)
        XCTAssertNil(center.sending.pending[7], "the feed has the message: the local bubble goes")
        XCTAssertEqual(model.items(permissions: true, host: .mac).map(\.id), ["m40"])
    }

    func testABusyRefusalPutsTheTextBackWithTheReason() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.addQuote("the SSO deadline")
        model.setText("When?")
        model.send(list: nil)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let sent = try XCTUnwrap(try recorder.params(ChatTurnParams.self).first)
        XCTAssertEqual(sent.text, ChatQuoteReply.compose(quotes: [ChatQuoteDraft(quote: "the SSO deadline", comment: "")], typed: "When?"))

        var snapshot = center.snapshot
        snapshot.failures = [RecordingChatSender.actionID(2): ChatActionFailure(
            reason: .conversationBusy, message: "This chat is answering on the Mac."
        )]
        center.apply(snapshot)
        try await poll({ model.draft.text == "When?" }, "text back")
        XCTAssertEqual(model.draft.quotes.map(\.quote), ["the SSO deadline"])
        XCTAssertEqual(model.composer(list: nil).line, "This chat is answering on the Mac.")
        XCTAssertNil(pendingOwner(model), "no bubble for a refused send")
    }

    func testANewChatCreatesThenUploadsThenSends() async throws {
        var uploaded: [ChatAttachmentUploadPayload] = []
        let uploads = ChatUploads { payload, _ in uploaded.append(payload) }
        let center = ChatFixture.center(recorder, sleeper: sleeper, uploads: uploads)
        let model = center.conversation(.new, ticks: ChatTicks().stream)
        model.appear(online: true)
        model.attach(data: Data("notes".utf8), fileName: "notes.md")
        model.setRouting(ChatRouting(mode: "pinned", provider: "claude", model: "opus"))
        model.setText("Read this")
        model.send(list: nil)
        try await poll({ !((try? self.recorder.params(ChatNewParams.self)) ?? []).isEmpty }, "chat_new")
        XCTAssertEqual(try recorder.params(ChatNewParams.self).first?.routing, ChatRouting(mode: "pinned", provider: "claude", model: "opus"))
        center.receiveApplied(applied(1, kind: .chatNew, result: ["conversation_id": .integer(88)]))
        try await poll({ uploaded.count == 1 }, "upload sent")
        XCTAssertEqual(uploaded.first?.conversationID, 88)
        XCTAssertEqual(model.conversationID, 88, "the screen follows the new chat")
        XCTAssertTrue(try recorder.params(ChatTurnParams.self).isEmpty, "the turn waits for the upload")

        var echo = try XCTUnwrap(uploaded.first)
        echo.status = .applied
        echo.attachmentID = 501
        center.sending.receiveUpload(echo)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.attachmentIDs, [501])
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.conversationID, 88)
    }

    func testARefusedUploadBringsTheDraftBackWithRetry() async throws {
        var uploaded: [ChatAttachmentUploadPayload] = []
        let center = ChatFixture.center(recorder, sleeper: sleeper, uploads: ChatUploads { payload, _ in uploaded.append(payload) })
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        model.attach(data: Data("notes".utf8), fileName: "notes.md")
        model.setText("Read this")
        model.send(list: nil)
        try await poll({ uploaded.count == 1 }, "upload sent")
        var echo = try XCTUnwrap(uploaded.first)
        echo.status = .failed
        echo.errorMessage = "notes.md is larger than 262 KB"
        center.sending.receiveUpload(echo)
        try await poll({ model.draft.text == "Read this" }, "draft back")
        let file = try XCTUnwrap(model.draft.attachments.first)
        XCTAssertEqual(file.state, .failed("notes.md is larger than 262 KB"))
        model.retryAttachment(file.id)
        XCTAssertNotEqual(model.draft.attachments.first?.id, file.id, "a retry after a refusal is a fresh upload id")
        XCTAssertTrue(try recorder.params(ChatTurnParams.self).isEmpty)
    }

    func testOfflineNothingIsSent() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: false)
        model.setText("Hello")
        XCTAssertFalse(model.composer(list: nil).canSend)
        model.send(list: nil)
        await Task.yield()
        XCTAssertTrue(recorder.sent.isEmpty, "D3: nothing is queued while the hub is away")
        XCTAssertEqual(model.draft.text, "Hello", "the draft stays")
    }
}

/// Approvals (spec §4.5, mockup 2c): Approve and Reject send `chat_action_answer` with the hash shown; without the
/// `permissions` grant the card points to the hub; a stale hash comes back as "The action changed — look again".
@MainActor
final class ChatApprovalWiringTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var center: ChatsCenter!
    private var model: ChatConversationModel!
    private let action = ChatFeed.Action(
        id: 31, tool: "send_slack_message", title: "Send Slack message", argsDisplay: "#release · acme", argsSHA256: "abc123", status: "pending"
    )

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        center = ChatFixture.center(recorder, sleeper: sleeper)
        model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: [ChatFixture.message(1, "user")], actions: [action]))
        center.apply(snapshot)
        model.appear(online: true)
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func card(permissions: Bool = true) -> ChatApprovalCardModel? {
        for case let .actions(cards) in model.items(permissions: permissions, host: .mac) { return cards.first }
        return nil
    }

    func testApproveSendsTheShownHash() async throws {
        let card = try XCTUnwrap(card())
        XCTAssertTrue(card.canAnswer)
        XCTAssertEqual(card.toneUse.tone, PhoneTone.waitingForYou)
        model.answer(card.action, .approve)
        try await poll({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "answer")
        let expected = ChatActionAnswerParams(actionID: 31, decision: .approve, argsSHA256: "abc123")
        XCTAssertEqual(try recorder.params(ChatActionAnswerParams.self), [expected])
        try await poll({ self.card()?.line == ChatApprovalCardModel.sendingLine }, "in flight")
        XCTAssertFalse(try XCTUnwrap(self.card()).canAnswer)
    }

    func testWithoutPermissionsTheCardPointsToTheHub() throws {
        let card = try XCTUnwrap(card(permissions: false))
        XCTAssertFalse(card.showsButtons)
        XCTAssertEqual(card.line, "Approve on the Mac")
    }

    func testAStaleHashSaysTheActionChanged() async throws {
        model.answer(action, .reject)
        try await poll({ !self.model.answering.isEmpty }, "queued")
        let outboxID = try XCTUnwrap(model.answering[31])
        var snapshot = center.snapshot
        snapshot.failures = [outboxID: ChatActionFailure(reason: .changed, message: "changed")]
        center.apply(snapshot)
        XCTAssertEqual(card()?.line, "The action changed — look again")
        XCTAssertEqual(card()?.canAnswer, true, "look again, then answer again")
    }

    func testASettledActionShowsItsOutcomeInGrey() throws {
        var snapshot = center.snapshot
        let done = ChatFeed.Action(
            id: 31, tool: "send_slack_message", title: "Send Slack message", argsDisplay: "", argsSHA256: "abc123", status: "applied"
        )
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: [ChatFixture.message(1, "user")], actions: [done]))
        center.apply(snapshot)
        let card = try XCTUnwrap(card())
        XCTAssertEqual(card.line, "Done")
        XCTAssertFalse(card.toneUse.isWaitingOrAsk)
    }
}

/// The composer (spec §6.2, mockups 2a, 2b, 2e, 2h, 2i).
@MainActor
final class ChatComposerModelTests: XCTestCase {
    private let list = ChatList(
        conversations: [], projects: [.init(id: 7, name: "acme-platform")],
        models: [.init(provider: "claude", model: "", displayName: "Claude", images: true, pdf: true),
                 .init(provider: "claude", model: "opus", displayName: "Claude Opus", images: true, pdf: true)]
    )

    func testANewChatHasEditableChipsAndTheMessagePlaceholder() {
        var draft = ChatDraft()
        let fresh = ChatComposerModel(draft: draft, isNew: true, online: true, lease: nil, sending: false, list: list, conversation: nil)
        XCTAssertEqual(fresh.placeholder, "Message")
        XCTAssertEqual(fresh.modelChip, .init(label: "Auto · Claude", editable: true))
        XCTAssertEqual(fresh.projectChip, .init(label: "No project", editable: true))
        XCTAssertFalse(fresh.canSend)
        draft.routing = ChatRouting(mode: "pinned", provider: "claude", model: "opus")
        draft.projectID = 7
        draft.text = "Hi"
        let picked = ChatComposerModel(draft: draft, isNew: true, online: true, lease: nil, sending: false, list: list, conversation: nil)
        XCTAssertEqual(picked.modelChip.label, "Claude Opus")
        XCTAssertEqual(picked.projectChip.label, "acme-platform")
        XCTAssertTrue(picked.canSend)
        XCTAssertEqual(ChatComposerModel.modelOptions(list).map(\.label), ["Auto", "Claude", "Claude Opus"])
    }

    func testChipsLockAfterTheFirstMessage() {
        let conversation = ChatFeed.Conversation(id: 3, title: "T", routing: .init(mode: "auto"), actualProvider: "claude")
        let model = ChatComposerModel(
            draft: ChatDraft(), isNew: false, online: true, lease: nil, sending: false, list: list, conversation: conversation
        )
        XCTAssertEqual(model.placeholder, "Ask a follow-up")
        XCTAssertEqual(model.modelChip, .init(label: "Auto · Claude", editable: false))
        XCTAssertEqual(model.projectChip, .init(label: "No project", editable: false))
    }

    func testSendBecomesStopWhileATurnRunsAndTheDraftWaits() {
        let draft = ChatDraft(text: "next")
        let busy = ChatComposerModel(
            draft: draft, isNew: false, online: true, lease: .init(owner: "hub", turnID: "t"), sending: false, list: list, conversation: nil
        )
        XCTAssertTrue(busy.showsStop)
        XCTAssertTrue(busy.canStop)
        XCTAssertFalse(busy.canSend)
    }

    func testOfflineEverythingIsOff() {
        let model = ChatComposerModel(
            draft: ChatDraft(text: "x"), isNew: false, online: false, lease: nil, sending: false, list: list, conversation: nil
        )
        XCTAssertFalse(model.canSend)
        XCTAssertFalse(model.canAttach)
        XCTAssertEqual(ChatText.asleepSending(.mac), "Your Mac is asleep — sending works when it wakes.")
    }

    func testQuotesUseTheMacFormatAndTheirPlaceholder() {
        let quote = ChatQuoteDraft(quote: "the SSO deadline and the export API", comment: "")
        let model = ChatComposerModel(
            draft: ChatDraft(text: "", quotes: [quote]), isNew: false, online: true, lease: nil, sending: false, list: list, conversation: nil
        )
        XCTAssertEqual(model.placeholder, "Ask about the quote")
        XCTAssertEqual(model.sendText, ChatQuoteReply.compose(quotes: [quote], typed: ""))
        XCTAssertTrue(model.canSend)
    }

    func testTheLengthCapCountsUnicodeScalars() {
        let long = String(repeating: "é", count: 32_001)
        let model = ChatComposerModel(
            draft: ChatDraft(text: long), isNew: false, online: true, lease: nil, sending: false, list: list, conversation: nil
        )
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.line, ChatComposerModel.overLimitLine)
    }

    func testDraftsAreKeptPerConversation() {
        let store = ChatDraftStore()
        store.update(1) { $0.text = "one" }
        store.update(2) { $0.text = "two" }
        XCTAssertEqual(store.draft(1).text, "one")
        XCTAssertEqual(store.draft(2).text, "two")
        store.move(from: 1, to: 9)
        XCTAssertEqual(store.draft(9).text, "one")
        XCTAssertEqual(store.draft(1).text, "")
    }
}
