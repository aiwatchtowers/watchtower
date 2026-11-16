import WatchtowerChatText
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// A feed record replaced after a relay reconnect (spec §7 "Relay drops mid-stream"): the latest record renders
/// whole, rows keep their ids, nothing doubles or goes missing, whatever the text did.
@MainActor
final class ChatFeedReconnectTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var center: ChatsCenter!

    override func setUp() async throws {
        sleeper = TickSleeper()
        center = ChatFixture.center(RecordingChatSender(), sleeper: sleeper)
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func show(_ feed: ChatFeed) {
        var snapshot = center.snapshot
        snapshot.feeds[feed.conversation.id] = ChatFixture.entry(feed)
        center.apply(snapshot)
    }

    private func texts(_ items: [ChatFeedItem]) -> [String: String] {
        var out: [String: String] = [:]
        for item in items {
            switch item {
            case let .owner(owner): out[item.id] = owner.text
            case let .answer(answer): out[item.id] = answer.message.text
            default: break
            }
        }
        return out
    }

    func testTheLatestRecordRendersWholeAfterAGap() {
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        let hub = ChatFeed.Lease(owner: "hub", turnID: "t")
        let first = [ChatFixture.message(1, "user", "Q"), ChatFixture.message(2, "assistant", "The plan moves", status: "partial")]
        show(ChatFixture.feed(messages: first, lease: hub))
        let before = model.items(permissions: true, host: .mac)
        XCTAssertEqual(before.map(\.id), ["m1", "m2"])

        // Versions skipped while the relay was down: the answer finished, a new turn began, an older one was cut.
        show(ChatFixture.feed(messages: [
            ChatFixture.message(1, "user", "Q"), ChatFixture.message(2, "assistant", "Short."),
            ChatFixture.message(3, "user", "And?"), ChatFixture.message(4, "assistant", "Longer than before, and more.", status: "partial")
        ], lease: hub))
        let after = model.items(permissions: true, host: .mac)
        XCTAssertEqual(after.map(\.id), ["m1", "m2", "m3", "m4"], "each message once, in order")
        XCTAssertEqual(texts(after), ["m1": "Q", "m2": "Short.", "m3": "And?", "m4": "Longer than before, and more."])
        guard case let .answer(last) = after.last else { return XCTFail("an answer last") }
        XCTAssertTrue(last.isStreaming)
        guard case let .answer(done) = after[1] else { return XCTFail("an answer") }
        XCTAssertFalse(done.isStreaming)
    }

    func testAPartialArtifactFenceStaysHiddenWhileStreaming() {
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        let text = "Here is a draft:\n\n:::artifact key=\"reply\" kind=\"email\" title=\"Reply to vendor\" to=\"vendor@example.com\"\nHello, thank"
        show(ChatFixture.feed(messages: [ChatFixture.message(1, "user"), ChatFixture.message(2, "assistant", text, status: "partial")],
                              lease: .init(owner: "hub", turnID: "t")))
        guard case let .answer(streaming) = model.items(permissions: true, host: .mac).last else { return XCTFail("answer") }
        XCTAssertFalse(streaming.segments.contains { if case .artifact = $0 { true } else { false } }, "the open fence is hidden")
        XCTAssertFalse(streaming.segments.contains { if case let .markdown(_, body) = $0 { body.contains(":::artifact") } else { false } })

        show(ChatFixture.feed(
            messages: [ChatFixture.message(1, "user"), ChatFixture.message(2, "assistant", text + " you.\n:::\n")],
            artifacts: [ChatFeed.Artifact(key: "reply", kind: "email", title: "Reply to vendor", version: 2, content: "Hello, thank you.")]
        ))
        guard case let .answer(done) = model.items(permissions: true, host: .mac).last else { return XCTFail("answer") }
        let cards = done.segments.compactMap { if case let .artifact(card) = $0 { card } else { nil } }
        XCTAssertEqual(cards.map(\.kindLabel), ["Email · v2"])
        let artifact = model.artifact("reply")
        XCTAssertEqual(artifact?.meta["to"], "vendor@example.com")
        XCTAssertEqual(artifact?.content, "Hello, thank you.")
    }
}

/// Retry, Regenerate, Edit and ‹ i/n › (spec §6.2, mockups 2a, 2d).
@MainActor
final class ChatTurnActionsTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var center: ChatsCenter!
    private var model: ChatConversationModel!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        center = ChatFixture.center(recorder, sleeper: sleeper)
        model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func show(_ messages: [ChatFeed.Message]) {
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: messages))
        center.apply(snapshot)
    }

    private func answer(_ id: Int64) throws -> ChatFeedItem.Answer {
        let item = model.items(permissions: true, host: .mac).first { $0.id == "m\(id)" }
        guard case let .answer(answer)? = item else { throw XCTSkip("no answer \(id)") }
        return answer
    }

    func testRetryOnARetryableErrorSendsRegenerate() async throws {
        model.appear(online: true)
        let failed = ChatFixture.message(2, status: "error", errorCode: "rate_limit", errorMessage: "Claude hit its usage limit.")
        show([ChatFixture.message(1, "user", "Q"), failed])
        let card = try XCTUnwrap(try answer(2).error)
        XCTAssertTrue(card.retryable)
        XCTAssertEqual(card.line, "Claude hit its usage limit.")
        XCTAssertEqual(ChatFeedItem.ErrorCard.title, "The answer stopped")
        model.regenerate(2)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self), [ChatTurnParams(conversationID: 7, mode: .regenerate, messageID: 2, text: "")])
    }

    func testANonRetryableErrorHasNoRetry() throws {
        show([ChatFixture.message(1, "user"), ChatFixture.message(2, status: "error", errorCode: "auth")])
        let card = try XCTUnwrap(try answer(2).error)
        XCTAssertFalse(card.retryable)
        XCTAssertEqual(card.line, ChatErrorText.message(for: "auth", provider: "claude"), "the Mac's table, its sign-in hint included")
    }

    func testRegenerateOnTheLastAnswerSendsRegenerate() async throws {
        model.appear(online: true)
        show([ChatFixture.message(1, "user"), ChatFixture.message(2)])
        XCTAssertTrue(try answer(2).isLast)
        model.regenerate(2)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "turn sent")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.mode, .regenerate)
        XCTAssertEqual(try recorder.params(ChatTurnParams.self).first?.messageID, 2)
    }

    func testEditFromTheOwnerBubbleSendsEditWithThatMessage() async throws {
        show([ChatFixture.message(1, "user", "Old question"), ChatFixture.message(2)])
        model.appear(online: true)
        guard case let .owner(owner)? = model.items(permissions: true, host: .mac).first else { return XCTFail("owner") }
        XCTAssertTrue(owner.canEdit)
        model.startEdit(1, text: owner.text)
        XCTAssertEqual(model.composer(list: nil).line, ChatComposerModel.editingLine)
        model.setText("New question")
        model.send(list: nil)
        try await poll({ (try? self.recorder.params(ChatTurnParams.self).count) == 1 }, "edit sent")
        XCTAssertEqual(try recorder.params(ChatTurnParams.self), [ChatTurnParams(conversationID: 7, mode: .edit, messageID: 1, text: "New question")])
    }

    func testOfflineNoTurnActionIsQueued() async throws {
        let lease = ChatFeed.Lease(owner: "hub", turnID: "t")
        var snapshot = center.snapshot
        let messages = [ChatFixture.message(1, "user"), ChatFixture.message(5, siblings: .init(index: 2, count: 3, ids: [3, 5, 9]))]
        let action = ChatFeed.Action(id: 4, tool: "t", title: "T", argsDisplay: "", argsSHA256: "h", status: "pending")
        snapshot.feeds[7] = ChatFixture.entry(ChatFixture.feed(messages: messages, lease: lease, actions: [action]))
        center.apply(snapshot)
        model.appear(online: false)
        let answer = try answer(5)
        model.selectBranch(answer.message, step: 1)
        model.regenerate(5)
        model.stop()
        model.answer(try XCTUnwrap(model.feed?.actions.first), .approve)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(recorder.sent.isEmpty, "D3: ‹ ›, Regenerate, Stop and Approve queue nothing while the hub is away")
    }

    func testBranchArrowsSelectTheSibling() async throws {
        model.appear(online: true)
        show([ChatFixture.message(1, "user"), ChatFixture.message(5, siblings: .init(index: 2, count: 3, ids: [3, 5, 9]))])
        let answer = try answer(5)
        model.selectBranch(answer.message, step: -1)
        model.selectBranch(answer.message, step: 1)
        try await poll({ (try? self.recorder.params(ChatBranchSelectParams.self).count) == 2 }, "two selects")
        XCTAssertEqual(try recorder.params(ChatBranchSelectParams.self).map(\.messageID), [3, 9])
    }
}

/// "Load earlier messages" (spec §4.6, mockup 2i): `chat_page` before the oldest message, the page stitched under
/// the feed, 30 s → "The Mac did not answer" + Retry; a search hit pages until its message is on screen.
@MainActor
final class ChatPagingModelTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var center: ChatsCenter!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        center = ChatFixture.center(recorder, sleeper: sleeper)
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func apply(feed: ChatFeed, pages: [Int64: ChatPageEntry] = [:]) {
        var snapshot = center.snapshot
        snapshot.feeds[7] = ChatFixture.entry(feed)
        snapshot.pages[7] = pages
        center.apply(snapshot)
    }

    func testAPageStitchesUnderTheFeed() async throws {
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        apply(feed: ChatFixture.feed(messages: [ChatFixture.message(61, "user"), ChatFixture.message(62)], hasMore: true))
        XCTAssertEqual(model.earlier, .more)
        model.loadEarlier()
        XCTAssertEqual(model.earlier, .loading)
        try await poll({ !((try? self.recorder.params(ChatPageParams.self)) ?? []).isEmpty }, "page asked")
        XCTAssertEqual(try recorder.params(ChatPageParams.self), [ChatPageParams(conversationID: 7, beforeMessageID: 61)])

        apply(feed: ChatFixture.feed(messages: [ChatFixture.message(61, "user"), ChatFixture.message(62)], hasMore: true),
              pages: [61: ChatFixture.page([ChatFixture.message(59, "user"), ChatFixture.message(60)], hasMore: false)])
        XCTAssertEqual(model.messages.map(\.id), [59, 60, 61, 62])
        XCTAssertNil(model.earlier, "the last page says there is no more")
    }

    func testAnUnansweredPageShowsNoAnswerAndRetryAsksAgain() async throws {
        let model = center.conversation(ChatRoute(id: 7), ticks: ChatTicks().stream)
        model.appear(online: true)
        apply(feed: ChatFixture.feed(messages: [ChatFixture.message(61, "user"), ChatFixture.message(62)], hasMore: true))
        model.loadEarlier()
        try await poll({ self.sleeper.waitingCount == 2 }, "open and page patience")
        sleeper.tick()
        try await poll({ model.earlier == .noAnswer }, "no answer")
        model.loadEarlier()
        XCTAssertEqual(model.earlier, .loading)
        try await poll({ (try? self.recorder.params(ChatPageParams.self).count) == 2 }, "asked again")
    }

    func testASearchHitPagesUntilItsMessageShows() async throws {
        let model = center.conversation(ChatRoute(id: 7, messageID: 21), ticks: ChatTicks().stream)
        apply(feed: ChatFixture.feed(messages: [ChatFixture.message(61, "user"), ChatFixture.message(62)], hasMore: true))
        model.appear(online: true)
        try await poll({ (try? self.recorder.params(ChatPageParams.self).count) == 1 }, "first page")
        apply(feed: ChatFixture.feed(messages: [ChatFixture.message(61, "user"), ChatFixture.message(62)], hasMore: true),
              pages: [61: ChatFixture.page([ChatFixture.message(40, "user"), ChatFixture.message(41)], hasMore: true)])
        model.followFocus()
        try await poll({ (try? self.recorder.params(ChatPageParams.self).count) == 2 }, "second page")
        XCTAssertEqual(try recorder.params(ChatPageParams.self).last?.beforeMessageID, 40)
        apply(feed: ChatFixture.feed(messages: [ChatFixture.message(61, "user"), ChatFixture.message(62)], hasMore: true),
              pages: [61: ChatFixture.page([ChatFixture.message(40, "user"), ChatFixture.message(41)], hasMore: true),
                      40: ChatFixture.page([ChatFixture.message(20, "user"), ChatFixture.message(21)], hasMore: true)])
        model.followFocus()
        await Task.yield()
        XCTAssertEqual(try recorder.params(ChatPageParams.self).count, 2, "the hit is on screen: no more pages")
    }
}
