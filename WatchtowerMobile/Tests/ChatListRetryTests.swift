import ChatWire
import WatchtowerKit
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// "Couldn't load chats" → Retry (iPhone chat mockup 1h): the phone asks the hub to publish `chat_list` again with
/// `chat_feed_request` for conversation 0, which watches nothing.
@MainActor
final class ChatListRetryTests: XCTestCase {
    func testRetrySendsAFeedRequestForConversationZero() async throws {
        let recorder = RecordingChatSender()
        let center = ChatsCenter(sender: recorder.sender) { _ in }
        let queued = await center.retryList()
        XCTAssertTrue(queued)
        XCTAssertEqual(recorder.sent.map(\.kind), [.chatFeedRequest])
        let params = try ChatFeedRequestParams(wireParams: try XCTUnwrap(recorder.sent.first).params)
        XCTAssertEqual(params.conversationID, 0)
        XCTAssertEqual(params.purpose, .prefetch, "never counts as the phone looking at a chat")
    }

    func testARetryThatCannotBeQueuedSaysSo() async {
        let recorder = RecordingChatSender()
        recorder.fails = true
        let center = ChatsCenter(sender: recorder.sender) { _ in }
        let queued = await center.retryList()
        XCTAssertFalse(queued)
    }

    /// The queued request goes through the outbox with no entity, as every chat action.
    func testTheAppSenderQueuesThroughTheOutboxWithoutAnEntity() async throws {
        let sleeper = TickSleeper()
        let sleep: @Sendable (Duration) async throws -> Void = { try await sleeper.sleep($0) }
        let session = try HubSession(
            transport: InMemoryCloudTransport(), replicaPath: try makeReplicaPath(), backend: .inMemoryDemo,
            defaults: try makeDefaults(), recordingsDirectory: try makeRecordingsDirectory(), sleep: sleep
        )
        addTeardownBlock { @MainActor in sleeper.cancelAll() }
        closeAtTeardown(session)
        try await session.chats.sender(ChatFeedRequestParams(conversationID: 0, purpose: .prefetch))
        let pending = try session.store.pendingActions().filter { $0.action.kind == .chatFeedRequest }
        XCTAssertEqual(pending.count, 1)
        XCTAssertNil(pending.first?.entityRecordName)
        let params = try ChatFeedRequestParams(wireParams: try XCTUnwrap(pending.first).action.params)
        XCTAssertEqual(params.conversationID, 0)
    }

    /// A chat action refused for the grant puts the gate on "not allowed"; the next one that goes clears it.
    func testTheNewestChatRefusalIsTheGatesRefusal() {
        func action(_ id: String, _ kind: ActionKind, at seconds: TimeInterval) -> ActionRequestPayload {
            ActionRequestPayload(
                id: id, kind: kind, entityID: nil, params: [:], createdAt: ChatFixture.now.addingTimeInterval(seconds), deviceID: "phone"
            )
        }
        let refused = PendingAction(
            id: "a", action: action("a", .chatSearch, at: 0), entityRecordName: nil, createdAt: ChatFixture.now, state: .failed,
            errorMessage: "This phone may not use chat", reason: .deviceNotAllowed, result: nil, echoStatus: nil,
            actionSeq: nil, epoch: nil, delivery: nil, undeliveredReason: nil
        )
        XCTAssertEqual(ChatsSnapshot.refusal(in: [refused]), "This phone may not use chat")
        let later = PendingAction(
            id: "b", action: action("b", .chatFeedRequest, at: 5), entityRecordName: nil, createdAt: ChatFixture.now.addingTimeInterval(5),
            state: .pending, errorMessage: nil, reason: nil, result: nil, echoStatus: nil,
            actionSeq: nil, epoch: nil, delivery: nil, undeliveredReason: nil
        )
        XCTAssertNil(ChatsSnapshot.refusal(in: [refused, later]))
        let otherKind = PendingAction(
            id: "c", action: action("c", .sessionInput, at: 9), entityRecordName: nil, createdAt: ChatFixture.now.addingTimeInterval(9),
            state: .failed, errorMessage: "typing", reason: .deviceNotAllowed, result: nil, echoStatus: nil,
            actionSeq: nil, epoch: nil, delivery: nil, undeliveredReason: nil
        )
        XCTAssertEqual(ChatsSnapshot.refusal(in: [refused, otherKind]), "This phone may not use chat", "other kinds do not count")
    }
}
