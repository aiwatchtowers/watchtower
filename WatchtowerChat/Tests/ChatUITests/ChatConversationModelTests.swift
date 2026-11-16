import ChatWire
import WatchtowerChatText
import XCTest
@testable import ChatUI

/// The conversation and composer models over a fake client (unified chat spec §8 rows, CHAT-01/02).
@MainActor
final class ChatConversationModelTests: XCTestCase {
    private var client: FakeChatClient!
    private var conversation: ChatConversationModel!
    private var composer: ChatComposerModel!
    private var clock: ManualClock!

    override func setUp() async throws {
        client = FakeChatClient()
        clock = ManualClock()
        conversation = ChatConversationModel(client: client, conversationID: 7, clock: clock)
        composer = ChatComposerModel(conversation: conversation)
        conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [ChatUIFixtures.message(2, text: "Hi.")])))
    }

    override func tearDown() async throws {
        conversation.stop()
    }

    private func turnRequest(_ op: ChatOperation?) -> ChatTurnRequest? {
        guard case .turn(let request)? = op else { return nil }
        return request
    }

    private static let started = ChatEcho.applied(.turn(ChatTurnStarted(userMessageID: 3, assistantMessageID: 4, turnID: "t1")))

    func testStateLineCopyIsPinned() {
        XCTAssertNil(ChatStateLine.content(for: .connected))
        XCTAssertEqual(ChatStateLine.content(for: .starting), .init(text: "Chat is starting…", action: nil))
        XCTAssertEqual(ChatStateLine.content(for: .unavailable),
                       .init(text: "Chat is unavailable — Watchtower's background service is not running", action: "Retry"))
        XCTAssertEqual(ChatStateLine.content(for: .stoppedOnPurpose),
                       .init(text: "Chat needs Watchtower's background service, which is stopped", action: "Start"))
    }

    func testDaemonUnreachableKeepsDraftAndShowsRetry() async {
        composer.draft = "Where are we on Q3?"
        conversation.reachability = .unavailable
        XCTAssertFalse(composer.canSend)
        await composer.send()
        XCTAssertTrue(client.ops.isEmpty, "nothing is sent while the chat is unreachable")
        XCTAssertEqual(composer.draft, "Where are we on Q3?")
        XCTAssertEqual(composer.stateLine,
                       .init(text: "Chat is unavailable — Watchtower's background service is not running", action: "Retry"))
        var started = 0
        conversation.onStartDaemon = { started += 1 }
        conversation.performStateAction()
        XCTAssertEqual(started, 1, "Retry runs the start chain")
    }

    func testStoppedOnPurposeShowsStartAndDoesNotStartDaemon() {
        var started = 0
        conversation.onStartDaemon = { started += 1 }
        composer.draft = "kept"
        conversation.reachability = .stoppedOnPurpose
        XCTAssertEqual(composer.stateLine?.action, "Start")
        XCTAssertFalse(composer.canSend)
        XCTAssertEqual(started, 0, "an owner stop is never undone silently")
        conversation.performStateAction()
        XCTAssertEqual(started, 1, "only the tap starts it")
        XCTAssertEqual(composer.draft, "kept")
    }

    func testBusyEchoReturnsTextToComposer() async {
        client.respond { _ in .refused(code: "busy", message: "a turn is running") }
        composer.draft = "Second device text"
        await composer.send()
        XCTAssertEqual(composer.draft, "Second device text")
        XCTAssertEqual(composer.line, ChatConversationModel.busyLine)
    }

    func testRefusedSendRestoresDraft() async {
        client.respond { _ in .refused(code: "invalid", message: "The message is too long.") }
        composer.draft = "Some text"
        composer.quotes = [.init(quote: "quoted", comment: "")]
        await composer.send()
        XCTAssertEqual(composer.draft, "Some text")
        XCTAssertEqual(composer.quotes.count, 1, "the quotes stay with the text")
        XCTAssertEqual(composer.line, "The message is too long.")
    }

    /// BEHAVIOR CHAT-01 — see docs/inventory/chat.md
    func testChat01DraftStaysUntilApplied() async {
        let gate = Gate()
        client.respond { _ in
            await gate.wait()
            return Self.started
        }
        composer.draft = "Hello"
        let send = Task { await composer.send() }
        let op = await client.nextOp()
        XCTAssertEqual(turnRequest(op)?.text, "Hello")
        XCTAssertEqual(composer.draft, "Hello", "the text stays in the field until the engine applied it")
        XCTAssertFalse(composer.canSend, "Send is off while the send is in flight")
        await gate.release()
        await send.value
        XCTAssertEqual(composer.draft, "")
    }

    func testDroppedEchoResendsWithSameKeyNoDuplicate() async {
        conversation.start()
        client.respond { _ in throw FakeChatClient.Dropped() }
        client.respond { _ in Self.started }
        composer.draft = "Ship it"
        await composer.send()
        let keys = client.ops.compactMap { turnRequest($0)?.clientKey }
        XCTAssertEqual(keys.count, 2, "a lost answer goes again at once")
        XCTAssertEqual(Set(keys).count, 1, "the resend carries the same client key")
        XCTAssertEqual(composer.draft, "")
    }

    /// Lost twice: the send waits for the client's next `.connected`, shown as Reconnecting…, then goes again with
    /// the same key (the `ChatClient.reachability` contract: `.connected` again after every reconnect).
    func testDroppedTwiceWaitsForReconnectThenResendsSameKey() async {
        conversation.start()
        client.respond { _ in throw FakeChatClient.Dropped() }
        client.respond { _ in throw FakeChatClient.Dropped() }
        client.respond { _ in Self.started }
        composer.draft = "Ship it"
        let send = Task { await composer.send() }
        while !conversation.isWaitingToResend { await Task.yield() }
        XCTAssertEqual(composer.draft, "Ship it", "a lost answer keeps the text")
        XCTAssertEqual(composer.stateLine?.text, ChatConversationModel.reconnectingLine)
        conversation.reachability = .connected
        await send.value
        let keys = client.ops.compactMap { turnRequest($0)?.clientKey }
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(Set(keys).count, 1, "every resend carries the same client key")
        XCTAssertEqual(composer.draft, "")
        XCTAssertNil(composer.stateLine)
    }

    /// Reachability never changes after the drop: the send gives up when its patience runs out (the injected
    /// clock), keeps the text, says why, and Send is back.
    func testLostSendWithNoReconnectGivesUpAndKeepsDraft() async {
        conversation.start()
        client.respond { _ in throw FakeChatClient.Dropped() }
        client.respond { _ in throw FakeChatClient.Dropped() }
        composer.draft = "Ship it"
        let send = Task { await composer.send() }
        while clock.pendingSleeps == 0 { await Task.yield() }
        clock.fire()
        await send.value
        XCTAssertEqual(client.ops.count, 2)
        XCTAssertEqual(composer.draft, "Ship it")
        XCTAssertEqual(composer.line, ChatConversationModel.unreachableSendLine)
        XCTAssertFalse(conversation.isReconnecting)
        XCTAssertTrue(composer.canSend, "the composer is not left parked")
    }

    /// A failure that is not the transport is reported at once, never retried or parked.
    func testNonTransportErrorIsReportedNotRetried() async {
        conversation.start()
        client.respond { _ in throw FakeChatClient.Broken() }
        composer.draft = "Ship it"
        await composer.send()
        XCTAssertEqual(client.ops.count, 1)
        XCTAssertEqual(composer.draft, "Ship it")
        XCTAssertEqual(composer.line, ChatConversationModel.couldNotSend)
        XCTAssertFalse(conversation.isWaitingToResend)
    }

    func testSkillPickerSetsSkillAndRemovesTheTrigger() async {
        let catalog = [ChatSkill(name: "review", description: "Review a PR"), ChatSkill(name: "plan", description: "Plan")]
        client.respond { _ in .applied(.skills(catalog)) }
        composer.draft = "/rev"
        let hits = await composer.skillHits(cursor: 4)
        XCTAssertEqual(hits.map(\.name), ["review"])
        XCTAssertEqual(composer.pick(skill: hits[0], cursor: 4), 0)
        XCTAssertEqual(composer.skill, "review")
        XCTAssertEqual(composer.draft, "")
        composer.draft = "/"
        let all = await composer.skillHits(cursor: 1)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(client.ops, [.skillsList], "the catalog is read once")
        composer.draft = "summarise the thread"
        let none = await composer.skillHits(cursor: 5)
        XCTAssertTrue(none.isEmpty, "no `/` trigger, no picker")
        await composer.send()
        XCTAssertEqual(turnRequest(client.ops.last)?.compose?.skill, "review")
        XCTAssertNil(composer.skill, "a sent skill is cleared")
    }

    func testQuotedPassageGoesWithTheNextMessage() async {
        composer.addQuote("  keep the retry budget small ")
        composer.draft = "Why?"
        await composer.send()
        let text = turnRequest(client.ops.last)?.text ?? ""
        XCTAssertTrue(text.contains("keep the retry budget small"))
        XCTAssertTrue(text.contains("Why?"))
        XCTAssertTrue(composer.quotes.isEmpty)
    }

    func testReconnectAfterDropShowsSessionLost() throws {
        conversation.store.apply(.resync)
        XCTAssertTrue(conversation.isStale)
        XCTAssertEqual(conversation.messages.map(\.id), [2], "the last feed stays on screen")
        let lost = ChatUIFixtures.message(4, text: "Half an ans", status: "partial", errorCode: "session_lost")
        conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [ChatUIFixtures.message(3, role: "user", text: "Q"), lost])))
        XCTAssertFalse(conversation.isStale)
        let error = try XCTUnwrap(ChatMessageParts.parts(for: lost).first { $0.kind == ChatPartKind.error })
        XCTAssertTrue(ChatPartRegistry.viewType(for: error, context: ChatPartContext(message: lost)) == ErrorPartView.self)
        let payload = try XCTUnwrap(error.decodePayload(ChatErrorPayload.self))
        XCTAssertEqual(payload.code, "session_lost")
        XCTAssertTrue(ChatErrorText.isRetryable(payload.code), "the error card offers Retry")
    }

    func testRemoteTurnShowsStopAndStreams() async {
        let lease = ChatFeed.Lease(owner: "phone", turnID: "t9")
        let streaming = ChatUIFixtures.message(4, text: "Draft", status: "pending")
        let owner = ChatUIFixtures.message(3, role: "user", text: "Q")
        conversation.store.apply(.snapshot(ChatUIFixtures.feed(messages: [owner, streaming], lease: lease)))
        XCTAssertTrue(conversation.isTurnRunning)
        XCTAssertTrue(conversation.canStop, "a turn another device started has the normal Stop")
        conversation.store.apply(.messageUpsert(ChatUIFixtures.message(4, text: "Draft answer, streaming", status: "pending")))
        XCTAssertEqual(conversation.messages.last?.text, "Draft answer, streaming")
        composer.draft = "next"
        XCTAssertFalse(composer.canSend, "Send is off while that conversation's turn runs")
        await conversation.cancelTurn()
        XCTAssertEqual(client.ops, [.cancel(conversationID: 7, turnID: "t9")])
    }

    /// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
    func testChat02WaitingStepVisibleUntilEnd() {
        let waiting = ChatFeed.Step(name: "send_slack_message", outcome: .running, summary: "Waiting for your approval")
        let running = ChatUIFixtures.message(4, text: "Sending.", status: "pending", steps: [waiting])
        let parts = ChatMessageParts.parts(for: running)
        XCTAssertTrue(parts.contains { $0.kind == ChatPartKind.steps }, "the waiting step shows while the turn runs")
        XCTAssertEqual(StepsPartView.header(count: 1, running: true), "Working… · 1 step")
        let ended = ChatUIFixtures.message(4, text: "Sent.", status: "complete", steps: [
            ChatFeed.Step(name: "send_slack_message", outcome: .succeeded, summary: "Sent")
        ])
        XCTAssertTrue(ChatMessageParts.parts(for: ended).contains { $0.kind == ChatPartKind.steps }, "and after it ends")
        XCTAssertEqual(StepsPartView.header(count: 1, running: false), "Worked · 1 step")
    }

    func testConversationDeletedElsewhereShowsGoneAndKeepsDraft() async {
        composer.draft = "unsent words"
        conversation.store.apply(.gone)
        XCTAssertTrue(conversation.isGone)
        XCTAssertFalse(composer.canSend)
        XCTAssertEqual(composer.stateLine?.text, ChatConversationModel.goneLine)
        await composer.send()
        XCTAssertTrue(client.ops.isEmpty)
        XCTAssertEqual(composer.draft, "unsent words")
    }

    func testFirstSendCreatesTheConversation() async {
        let fresh = ChatConversationModel(client: client, conversationID: nil)
        let first = ChatComposerModel(conversation: fresh)
        var created: Int64?
        fresh.onConversationCreated = { created = $0 }
        client.respond { _ in .applied(.conversation(id: 12)) }
        client.respond { _ in Self.started }
        first.draft = "New topic"
        await first.send()
        XCTAssertEqual(created, 12)
        XCTAssertEqual(fresh.conversationID, 12)
        XCTAssertEqual(turnRequest(client.ops.last)?.conversationID, 12)
        XCTAssertEqual(first.draft, "")
    }

    func testFixedTextLeavesTheDraftAlone() async {
        composer.draft = "my own words"
        await composer.sendFixed("Please try again.")
        XCTAssertEqual(turnRequest(client.ops.first)?.text, "Please try again.")
        XCTAssertEqual(composer.draft, "my own words")
    }
}
