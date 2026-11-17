import ChatWire
import WatchtowerChatText
import XCTest
@testable import ChatUI

/// The composer model's Mac behaviours, now shared with the phone (#1822 T13): ↑ edits the last owner message, the
/// picker owned by the model, only live mentions go, the draft and its chips survive a lost host, and an unanswered
/// send's `client_key` is reused while its content is unchanged (final review M1).
@MainActor
final class ChatComposerModelPickerTests: XCTestCase {
    private var client: FakeChatClient!
    private var conversation: ChatConversationModel!
    private var composer: ChatComposerModel!
    private var clock: ManualClock!

    private static let owner = ChatUIFixtures.message(1, role: "user", text: "Summarise the Q3 threads")
    private static let started = ChatEcho.applied(.turn(ChatTurnStarted(userMessageID: 3, assistantMessageID: 4, turnID: "t1")))
    private let hits = [
        ChatEntityHit(kind: "person", id: "1:U1", label: "Anna", detail: "@anna"),
        ChatEntityHit(kind: "jira", id: "PAY-1", label: "PAY-1", detail: "Refund")
    ]

    override func setUp() async throws {
        client = FakeChatClient()
        clock = ManualClock()
        conversation = ChatConversationModel(client: client, conversationID: 7, clock: clock)
        composer = ChatComposerModel(conversation: conversation)
        conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [
            Self.owner, ChatUIFixtures.message(2, text: "Three threads.")
        ])))
    }

    override func tearDown() async throws {
        conversation.stop()
    }

    private func turnRequests() -> [ChatTurnRequest] {
        client.ops.compactMap { op in
            guard case .turn(let request) = op else { return nil }
            return request
        }
    }

    /// Opens the picker on `text` (caret at the end) and waits for its rows.
    private func open(_ text: String) async {
        composer.draft = text
        composer.picker.update(text: text, cursor: text.utf16.count)
        await composer.picker.searchSettled()
    }

    func testArrowUpEditsLastOwnerMessageOnlyWhenIdle() {
        conversation.store.apply(.snapshot(ChatUIFixtures.feed(
            messages: [Self.owner, ChatUIFixtures.message(2, text: "Three", status: "pending")],
            lease: ChatFeed.Lease(owner: "hub", turnID: "t0")
        )))
        composer.draft = ""
        composer.beginEditingLast()
        XCTAssertNil(composer.editing, "never while a turn runs")
        XCTAssertEqual(composer.draft, "")

        conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [Self.owner, ChatUIFixtures.message(2, text: "Three")])))
        composer.beginEditingLast()
        XCTAssertEqual(composer.editing, 1)
        XCTAssertEqual(composer.draft, "Summarise the Q3 threads")
    }

    func testSendCarriesOnlyLiveMentionsAndSkill() async {
        let skills = [ChatSkill(name: "review", description: "Review")]
        let hits = hits
        client.respond { _ in .applied(.skills(skills)) }
        await open("/re")
        let skillEdit = composer.picker.accept(index: 0, text: "/re", cursor: 3)
        composer.draft = skillEdit?.text ?? ""
        client.respond { _ in .applied(.entities(hits)) }
        await open(composer.draft + "Ask @an")
        composer.draft = composer.picker.accept(index: 0, text: composer.draft, cursor: composer.draft.utf16.count)?.text ?? ""
        client.respond { _ in .applied(.entities(hits)) }
        await open(composer.draft + "and @pa")
        composer.draft = composer.picker.accept(index: 1, text: composer.draft, cursor: composer.draft.utf16.count)?.text ?? ""
        XCTAssertEqual(composer.picker.mentions.map(\.label), ["Anna", "PAY-1"])
        composer.draft = composer.draft.replacingOccurrences(of: "@Anna ", with: "")

        client.respond { _ in Self.started }
        await composer.send()
        let compose = turnRequests().last?.compose
        XCTAssertEqual(compose?.mentions, [ChatCompose.Mention(kind: "jira", id: "PAY-1", label: "PAY-1")])
        XCTAssertEqual(compose?.skill, "review")
        XCTAssertTrue(composer.picker.mentions.isEmpty, "applied: the picker's mentions are cleared")
        XCTAssertNil(composer.picker.skill)
    }

    func testPickerKeysGoToPickerFirst() async {
        let hits = hits
        client.respond { _ in .applied(.entities(hits)) }
        await open("Ask @a")
        XCTAssertTrue(composer.picker.handle(.down, text: "Ask @a", cursor: 6).consumed)
        let enter = composer.picker.handle(.accept, text: "Ask @a", cursor: 6)
        XCTAssertTrue(enter.consumed)
        XCTAssertEqual(enter.edit?.text, "Ask @PAY-1 ", "the second row is inserted")
        XCTAssertFalse(composer.picker.handle(.accept, text: "Ask @PAY-1 ", cursor: 11).consumed,
                       "a closed picker leaves Enter to send")
    }

    func testHostGoneMidSendKeepsDraftQuotesAndChips() async {
        conversation.start()
        let hits = hits
        client.respond { _ in .applied(.entities(hits)) }
        await open("Ask @an")
        composer.draft = composer.picker.accept(index: 0, text: "Ask @an", cursor: 7)?.text ?? ""
        composer.skill = "review"
        composer.addQuote("the staging check was never run")
        client.respond { _ in .applied(.attachment(id: 41)) }
        await composer.attach(.path("/tmp/acme-notes.md"))
        let draft = composer.draft
        client.respond { _ in throw FakeChatClient.Dropped() }
        client.respond { _ in throw FakeChatClient.Dropped() }
        let send = Task { await composer.send() }
        while clock.pendingSleeps == 0 { await Task.yield() }
        clock.fire()
        await send.value
        XCTAssertEqual(composer.draft, draft)
        XCTAssertEqual(composer.quotes.map(\.quote), ["the staging check was never run"])
        XCTAssertEqual(composer.attachments.map(\.id), [41])
        XCTAssertEqual(composer.picker.mentions.map(\.label), ["Anna"])
        XCTAssertEqual(composer.picker.skill, "review")
        XCTAssertNotNil(composer.notice)
    }

    /// Sends "Ship it" whose answer is lost past the patience (the engine may have taken it).
    private func loseAnswer() async {
        client.respond { _ in throw FakeChatClient.Dropped() }
        client.respond { _ in throw FakeChatClient.Dropped() }
        let send = Task { await composer.send() }
        while clock.pendingSleeps == 0 { await Task.yield() }
        clock.fire()
        await send.value
    }

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md (final review M1)
    func testLostEchoResendReusesKeyWhileDraftUnchanged() async {
        conversation.start()
        composer.draft = "Ship it"
        await loseAnswer()
        client.respond { _ in Self.started }
        await composer.send()
        let keys = turnRequests().map(\.clientKey)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1, "Send again with the same draft is the same message: the engine answers the first")
        XCTAssertEqual(composer.draft, "")
    }

    func testEditedDraftAfterLostEchoGetsNewKey() async {
        conversation.start()
        composer.draft = "Ship it"
        await loseAnswer()
        composer.draft = "Ship it today"
        client.respond { _ in Self.started }
        await composer.send()
        let keys = turnRequests().map(\.clientKey)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[0], keys[1])
        XCTAssertNotEqual(keys[2], keys[0], "an edited draft is a new message")
    }

    func testSendWaitingForImportProceedsWhenImportFails() async {
        let gate = Gate()
        client.respond { _ in
            await gate.wait()
            return .refused(code: "invalid", message: "This provider reads no PDFs.")
        }
        let attach = Task { await composer.attach(.path("/tmp/acme-report.pdf")) }
        while composer.importing.isEmpty { await Task.yield() }
        _ = await client.nextOp()
        composer.draft = "Here is the report"
        client.respond { _ in Self.started }
        let send = Task { await composer.send() }
        while !composer.isWaitingForAttachments { await Task.yield() }
        await gate.release()
        await attach.value
        await send.value
        XCTAssertEqual(turnRequests().last?.attachmentIDs, [])
        XCTAssertEqual(turnRequests().last?.text, "Here is the report")
        XCTAssertTrue(composer.importing.isEmpty)
        XCTAssertEqual(composer.notice?.contains("acme-report.pdf"), true, "the refused file is named")
    }
}
