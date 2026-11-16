import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The conversation screen's model (iPhone chat spec §6.2–§6.3, mockups 2f, 2g): the open request and its 60 s
/// repeat, the 30 s patience, the Mac-run turn's line and Stop, and the read mark. Sleeps and repeats are stepped
/// by hand; nothing waits on the wall clock.
@MainActor
final class ChatConversationModelTests: XCTestCase {
    private var sleeper: TickSleeper!
    private var recorder: RecordingChatSender!
    private var ticks: ChatTicks!
    private var center: ChatsCenter!

    override func setUp() async throws {
        sleeper = TickSleeper()
        recorder = RecordingChatSender()
        ticks = ChatTicks()
        center = ChatFixture.center(recorder, sleeper: sleeper)
    }

    override func tearDown() async throws {
        sleeper.cancelAll()
    }

    private func model(_ id: Int64 = 7) -> ChatConversationModel {
        center.conversation(ChatRoute(id: id), ticks: ticks.stream)
    }

    private func show(_ feed: ChatFeed) {
        var snapshot = center.snapshot
        snapshot.feeds[feed.conversation.id] = ChatFixture.entry(feed)
        center.apply(snapshot)
    }

    func testOpeningSendsTheRequestAndRepeatsItEveryMinute() async throws {
        let model = model()
        model.appear(online: true)
        try await poll({ self.recorder.sent.count == 1 }, "open sent")
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self), [ChatFeedRequestParams(conversationID: 7, purpose: .open)])
        ticks.tick()
        try await poll({ (try? self.recorder.params(ChatFeedRequestParams.self).count) == 2 }, "repeat sent")
        model.disappear()
        ticks.tick()
        await Task.yield()
        XCTAssertEqual(try recorder.params(ChatFeedRequestParams.self).count, 2, "no repeat once the screen is gone")
    }

    func testThirtySecondsWithoutARecordIsNoAnswerAndRetryAsksAgain() async throws {
        let model = model()
        model.appear(online: true)
        XCTAssertEqual(model.placeholder, .loading)
        try await poll({ self.sleeper.waitingCount == 1 }, "patience")
        XCTAssertEqual(sleeper.requested, [.seconds(30)])
        sleeper.tick()
        try await poll({ model.placeholder == .noAnswer }, "no answer")
        XCTAssertEqual(ChatText.noAnswer(.mac), "The Mac did not answer")
        model.retryOpen()
        XCTAssertEqual(model.placeholder, .loading)
        try await poll({ (try? self.recorder.params(ChatFeedRequestParams.self).count) == 2 }, "retry sent")
    }

    func testOfflineSendsNothingAndANeverLoadedChatSaysSo() async throws {
        let model = model()
        model.appear(online: false)
        await Task.yield()
        XCTAssertTrue(recorder.sent.isEmpty)
        XCTAssertEqual(model.placeholder, .neverLoaded)
        XCTAssertEqual(ChatText.neverLoaded(.mac), "Open this chat once while your Mac is awake to read it here")
        model.setOnline(true)
        try await poll({ self.recorder.sent.count == 1 }, "the request goes when the hub answers")
    }

    func testAMacRunTurnShowsTheWatchLineAndStopCancelsIt() async throws {
        let model = model()
        model.appear(online: true)
        show(ChatFixture.feed(
            messages: [ChatFixture.message(1, "user", "Summarise"), ChatFixture.message(2, "assistant", "The roadmap has", status: "partial")],
            lease: .init(owner: "desktop", turnID: "turn-9")
        ))
        XCTAssertEqual(model.leaseLine(.mac), "Answering on your Mac — you can watch here.")
        let composer = model.composer(list: nil)
        XCTAssertTrue(composer.showsStop)
        XCTAssertTrue(composer.canStop)
        XCTAssertFalse(composer.canSend)
        model.stop()
        try await poll({ (try? self.recorder.params(ChatCancelParams.self)) == [ChatCancelParams(conversationID: 7, turnID: "turn-9")] }, "cancel")

        show(ChatFixture.feed(messages: [ChatFixture.message(1, "user")], lease: .init(owner: "hub", turnID: "t", waitingSlot: true)))
        XCTAssertEqual(model.leaseLine(.mac), ChatConversationModel.waitingForSlot)
        show(ChatFixture.feed(messages: [ChatFixture.message(1, "user")], lease: .init(owner: "hub", turnID: "t")))
        XCTAssertNil(model.leaseLine(.mac), "a hub turn streams here: no line")
    }

    func testReadGoesForTheNewestCompleteAnswerOnlyAndNeverBackwards() async throws {
        let model = model()
        show(ChatFixture.feed(messages: [ChatFixture.message(10, "user"), ChatFixture.message(11)]))
        model.markRead()
        XCTAssertFalse(recorder.sent.contains { $0.kind == .chatRead }, "not before the screen shows it")
        model.appear(online: true)
        try await poll({ (try? self.recorder.params(ChatReadParams.self)) == [ChatReadParams(conversationID: 7, messageID: 11)] }, "read 11")

        let streaming = [
            ChatFixture.message(10, "user"), ChatFixture.message(11), ChatFixture.message(12, "user"), ChatFixture.message(13, status: "partial")
        ]
        show(ChatFixture.feed(messages: streaming, lease: .init(owner: "hub", turnID: "t")))
        model.markRead()
        let done = [ChatFixture.message(10, "user"), ChatFixture.message(11), ChatFixture.message(12, "user"), ChatFixture.message(13)]
        show(ChatFixture.feed(messages: done))
        model.markRead()
        try await poll({ (try? self.recorder.params(ChatReadParams.self).count) == 2 }, "read 13")
        XCTAssertEqual(try recorder.params(ChatReadParams.self).last?.messageID, 13)

        // A record from before (a replay) never takes the mark back.
        show(ChatFixture.feed(messages: [ChatFixture.message(10, "user"), ChatFixture.message(11)]))
        model.markRead()
        await Task.yield()
        XCTAssertEqual(try recorder.params(ChatReadParams.self).map(\.messageID), [11, 13])
    }
}
