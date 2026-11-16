import ChatUI
import ChatWire
import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone half of CHAT-01 (spec §6.3, unified chat §6.3): the shared composer over `RelayChatClient` —
/// `chat_new` → uploads → `chat_turn`; the text stays in the composer until the turn is `applied`; a refused echo
/// (`conversation_busy`) leaves the text there with the reason.
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

    /// A conversation screen's models over the center's client, the hub answering.
    private func screen(_ center: ChatsCenter, _ route: ChatRoute, gate: ChatsGateModel = ChatsGateModel(ChatFixture.inputs()))
        -> (ChatConversationModel, ChatComposerModel) {
        center.setGate(gate)
        return center.conversation(route)
    }

    func testTheOwnerBubbleStaysPendingUntilApplied() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let (_, composer) = screen(center, ChatRoute(id: 7))
        composer.draft = "Summarise the Q3 roadmap"
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(composer.draft, "Summarise the Q3 roadmap", "the text stays until applied")
        XCTAssertFalse(composer.canSend, "one send at a time")
        XCTAssertEqual(center.sending.pending[7]?.text, "Summarise the Q3 roadmap")
        XCTAssertEqual(center.sending.pending[7]?.isApplied, false)

        center.receiveApplied(applied(1, kind: .chatTurn, result: [
            "user_message_id": .integer(40), "assistant_message_id": .integer(41), "turn_id": .string("t")
        ]))
        await send.value
        XCTAssertEqual(composer.draft, "", "applied: the composer empties")
        XCTAssertEqual(center.sending.pending[7]?.isApplied, true)
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: [ChatFixture.message(40, "user", "Summarise the Q3 roadmap")]))
        center.apply(snapshot)
        XCTAssertNil(center.sending.pending[7], "the feed has the message: the pending send goes")
    }

    func testABusyRefusalPutsTheTextBackWithTheReason() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let (_, composer) = screen(center, ChatRoute(id: 7))
        composer.addQuote("the SSO deadline")
        composer.draft = "When?"
        let send = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let sent = try XCTUnwrap(try recorder.params(ChatTurnParams.self).first)
        XCTAssertEqual(sent.text, ChatQuoteReply.compose(quotes: [ChatQuoteDraft(quote: "the SSO deadline", comment: "")], typed: "When?"))

        var snapshot = center.snapshot
        snapshot.failures = [RecordingChatSender.actionID(1): ChatActionFailure(
            reason: .conversationBusy, message: "This chat is answering on the Mac."
        )]
        center.apply(snapshot)
        await send.value
        XCTAssertEqual(composer.draft, "When?")
        XCTAssertEqual(composer.quotes.map(\.quote), ["the SSO deadline"])
        XCTAssertEqual(composer.line, "This chat is answering on the Mac.", "the hub's own reason")
        XCTAssertNil(center.sending.pending[7], "no pending send for a refused one")
        XCTAssertEqual(center.drafts.draft(7).text, "", "the composer keeps the text, not the draft store")
    }

    func testANewChatCreatesThenUploadsThenSends() async throws {
        var uploaded: [ChatAttachmentUploadPayload] = []
        let uploads = ChatUploads { payload, _ in uploaded.append(payload) }
        let center = ChatFixture.center(recorder, sleeper: sleeper, uploads: uploads)
        let (conversation, composer) = screen(center, .new)
        XCTAssertNil(center.attach(data: Data("notes".utf8), fileName: "notes.md", conversation: 0))
        composer.routing = ChatRouting(mode: "pinned", provider: "claude", model: "opus")
        composer.draft = "Read this"
        let send = Task { await composer.send() }
        try await poll({ !((try? self.recorder.params(ChatNewParams.self)) ?? []).isEmpty }, "chat_new")
        XCTAssertEqual(try recorder.params(ChatNewParams.self).first?.routing, ChatRouting(mode: "pinned", provider: "claude", model: "opus"))
        center.receiveApplied(applied(1, kind: .chatNew, result: ["conversation_id": .integer(88)]))
        try await poll({ uploaded.count == 1 }, "upload sent")
        XCTAssertEqual(uploaded.first?.conversationID, 88)
        XCTAssertEqual(conversation.conversationID, 88, "the screen follows the new chat")
        XCTAssertTrue(try recorder.params(ChatTurnParams.self).isEmpty, "the turn waits for the upload")

        var echo = try XCTUnwrap(uploaded.first)
        echo.status = .applied
        echo.attachmentID = 501
        center.sending.receiveUpload(echo)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.attachmentIDs, [501])
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.conversationID, 88)
        center.receiveApplied(applied(2, kind: .chatTurn, result: ["user_message_id": .integer(5)]))
        await send.value
        XCTAssertEqual(composer.draft, "")
    }

    /// I1: once the new chat exists, its draft is the chat's: the next New chat opens empty.
    func testANewChatsDraftMovesToItsChat() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let (_, composer) = screen(center, .new)
        composer.draft = "Hello"
        center.keepDraft(0, text: "Hello", quotes: [])
        let send = Task { await composer.send() }
        try await poll({ !((try? self.recorder.params(ChatNewParams.self)) ?? []).isEmpty }, "chat_new")
        center.receiveApplied(applied(1, kind: .chatNew, result: ["conversation_id": .integer(88)]))
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        center.receiveApplied(applied(2, kind: .chatTurn, result: ["user_message_id": .integer(5)]))
        await send.value
        XCTAssertEqual(center.drafts.draft(0).text, "")
        let (_, next) = center.conversation(.new)
        XCTAssertEqual(next.draft, "", "a second new chat starts empty")
    }

    /// The composer's skill and mentions and the send's client key travel on `chat_turn` (the relay contract).
    func testTheTurnCarriesComposeAndClientKey() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let (_, composer) = screen(center, ChatRoute(id: 7))
        composer.draft = "Status for @Alice"
        composer.skill = "weekly-report"
        composer.mentions = [ChatCompose.Mention(kind: "person", id: "U1", label: "Alice")]
        _ = Task { await composer.send() }
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        let sent = try XCTUnwrap(try recorder.params(ChatTurnParams.self).first)
        XCTAssertEqual(sent.compose, ChatCompose(skill: "weekly-report", mentions: [.init(kind: "person", id: "U1", label: "Alice")]))
        XCTAssertEqual(sent.clientKey?.isEmpty, false)
        XCTAssertEqual(try copy(center).outgoing().sends.first?.clientKey, sent.clientKey)
    }

    private func copy(_ center: ChatsCenter) -> ChatOfflineCopy { center.copy }

    func testARefusedUploadBringsTheDraftBackWithRetry() async throws {
        var uploaded: [ChatAttachmentUploadPayload] = []
        let center = ChatFixture.center(recorder, sleeper: sleeper, uploads: ChatUploads { payload, _ in uploaded.append(payload) })
        let (_, composer) = screen(center, ChatRoute(id: 7))
        XCTAssertNil(center.attach(data: Data("notes".utf8), fileName: "notes.md", conversation: 7))
        composer.draft = "Read this"
        let send = Task { await composer.send() }
        try await poll({ uploaded.count == 1 }, "upload sent")
        var echo = try XCTUnwrap(uploaded.first)
        echo.status = .failed
        echo.errorMessage = "notes.md is larger than 262 KB"
        center.sending.receiveUpload(echo)
        await send.value
        XCTAssertEqual(composer.draft, "Read this", "draft back")
        XCTAssertEqual(composer.line, "notes.md is larger than 262 KB")
        let file = try XCTUnwrap(center.drafts.draft(7).attachments.first)
        XCTAssertEqual(file.state, .failed("notes.md is larger than 262 KB"))
        center.retryAttachment(file.id, conversation: 7)
        XCTAssertNotEqual(center.drafts.draft(7).attachments.first?.id, file.id, "a retry after a refusal is a fresh upload id")
        XCTAssertTrue(try recorder.params(ChatTurnParams.self).isEmpty)
    }

    func testOfflineNothingIsSent() async throws {
        let center = ChatFixture.center(recorder, sleeper: sleeper)
        let (conversation, composer) = screen(center, ChatRoute(id: 7), gate: ChatsGateModel(ChatFixture.inputs(mac: .offline)))
        conversation.start()
        defer { conversation.stop() }
        try await poll({ conversation.reachability != .connected }, "the gate's state reached the screen")
        composer.draft = "Hello"
        XCTAssertFalse(composer.canSend)
        await composer.send()
        XCTAssertTrue(recorder.sent.isEmpty, "D3: nothing is queued while the hub is away")
        XCTAssertEqual(composer.draft, "Hello", "the draft stays")
        XCTAssertEqual(composer.stateLine?.text, ChatText.offline(.mac))
    }
}

/// Approvals (spec §4.5, mockup 2c): Approve and Reject send `chat_action_answer` with the hash shown, once; without the
/// `permissions` grant the card has no buttons and points to the hub; a stale hash comes back as "The action changed —
/// look again".
@MainActor
final class ChatApprovalWiringTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var center: ChatsCenter!
    private let action = ChatFeed.Action(
        id: 31, tool: "send_slack_message", title: "Send Slack message", argsDisplay: "#release · acme", argsSHA256: "abc123", status: "pending"
    )

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        center = ChatFixture.center(recorder, sleeper: sleeper)
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: [ChatFixture.message(1, "user")], actions: [action]))
        center.apply(snapshot)
        center.setGate(ChatsGateModel(ChatFixture.inputs()))
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func card(_ action: ChatFeed.Action? = nil, permissions: Bool = true) -> ChatApprovalCardModel {
        center.client.approvalCard(ChatApprovalPayload(action: action ?? self.action), permissions: permissions, host: .mac)
    }

    func testApproveSendsTheShownHash() async throws {
        let card = card()
        XCTAssertTrue(card.canAnswer)
        XCTAssertEqual(card.toneUse.tone, PhoneTone.waitingForYou)
        let answer = Task { await center.client.decide(card.payload, .approve, permissions: true) }
        try await poll({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "answer")
        let expected = ChatActionAnswerParams(actionID: 31, decision: .approve, argsSHA256: "abc123")
        XCTAssertEqual(try recorder.params(ChatActionAnswerParams.self), [expected])
        XCTAssertEqual(self.card().line, ChatApprovalCardModel.sendingLine, "in flight")
        XCTAssertFalse(self.card().canAnswer)
        XCTAssertFalse(self.card().state.canAnswer, "the shared card's buttons are off")
        await center.client.decide(card.payload, .approve, permissions: true)
        XCTAssertEqual(try recorder.params(ChatActionAnswerParams.self).count, 1, "a second tap sends nothing")
        var echo = ActionRequestPayload(id: RecordingChatSender.actionID(1), kind: .chatActionAnswer, entityID: nil, createdAt: ChatFixture.now)
        echo.status = .applied
        center.receiveApplied(echo)
        await answer.value
        XCTAssertNil(self.card().line)
    }

    func testWithoutPermissionsTheCardPointsToTheHub() async throws {
        let card = card(permissions: false)
        XCTAssertFalse(card.showsButtons)
        XCTAssertFalse(card.state.showsButtons, "the shared card draws no Approve or Reject")
        XCTAssertEqual(card.line, "Approve on the Mac")
        XCTAssertEqual(card.state.line, "Approve on the Mac")
        await center.client.decide(card.payload, .approve, permissions: false)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testAStaleHashSaysTheActionChanged() async throws {
        let answer = Task { await center.client.decide(ChatApprovalPayload(action: action), .reject, permissions: true) }
        try await poll({ (try? self.recorder.params(ChatActionAnswerParams.self).count) == 1 }, "queued")
        var snapshot = center.snapshot
        snapshot.failures = [RecordingChatSender.actionID(1): ChatActionFailure(reason: .changed, message: "changed")]
        center.apply(snapshot)
        await answer.value
        XCTAssertEqual(card().line, "The action changed — look again")
        XCTAssertEqual(card().canAnswer, true, "look again, then answer again")
    }

    func testASettledActionShowsItsOutcomeInGrey() throws {
        let done = ChatFeed.Action(
            id: 31, tool: "send_slack_message", title: "Send Slack message", argsDisplay: "", argsSHA256: "abc123", status: "applied"
        )
        let card = card(done)
        XCTAssertEqual(card.line, "Done")
        XCTAssertFalse(card.showsButtons)
        XCTAssertFalse(card.toneUse.isWaitingOrAsk)
    }
}
