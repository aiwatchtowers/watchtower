import ChatWire
import XCTest

/// The feed and list stores (unified chat spec §5.4): a snapshot replaces, an upsert replaces or appends by id, a
/// resync clears until the next snapshot.
@MainActor
final class ChatStoreTests: XCTestCase {
    private let conversation = ChatFeed.Conversation(id: 3, title: "Rollout")

    private func message(_ id: Int64, _ text: String, status: String = "complete") -> ChatFeed.Message {
        ChatFeed.Message(id: id, role: id.isMultiple(of: 2) ? "assistant" : "user", text: text, status: status,
                         createdAt: Date(timeIntervalSince1970: TimeInterval(id)))
    }

    func testFeedStoreAppliesSnapshotThenUpsertByID() {
        let store = ChatFeedStore()
        store.apply(.messageUpsert(message(1, "ignored before a snapshot")))
        XCTAssertNil(store.feed)

        let artifact = ChatFeed.Artifact(key: "q3", kind: "document", title: "Q3", version: 1, content: "x")
        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi"), message(2, "Hel")],
                                       hasMore: true, artifacts: [artifact])))
        store.apply(.messageUpsert(message(2, "Hello", status: "partial")))
        store.apply(.messageUpsert(message(2, "Hello there")))
        store.apply(.messageUpsert(message(3, "Thanks")))

        let feed = store.feed
        XCTAssertEqual(feed?.messages.map(\.id), [1, 2, 3])
        XCTAssertEqual(feed?.messages.map(\.text), ["Hi", "Hello there", "Thanks"])
        XCTAssertEqual(feed?.messages[1].status, "complete")
        XCTAssertEqual(feed?.hasMore, true)
        XCTAssertEqual(feed?.artifacts, [artifact])

        let renamed = ChatFeed.Conversation(id: 3, title: "Rollout notes", lease: .init(owner: "desktop", turnID: "t9"))
        store.apply(.conversation(renamed))
        XCTAssertEqual(store.feed?.conversation, renamed)
        XCTAssertEqual(store.feed?.messages.count, 3)

        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi")])))
        XCTAssertEqual(store.feed?.messages.map(\.id), [1])
        XCTAssertEqual(store.feed?.hasMore, false)
    }

    func testFeedStoreResyncClearsUntilSnapshot() {
        let store = ChatFeedStore()
        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi")])))
        store.apply(.resync)
        XCTAssertNil(store.feed)
        store.apply(.messageUpsert(message(2, "lost in the gap")))
        store.apply(.conversation(conversation))
        XCTAssertNil(store.feed)
        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi"), message(2, "Hello")])))
        XCTAssertEqual(store.feed?.messages.map(\.text), ["Hi", "Hello"])
    }

    func testListStoreTakesSnapshotsAndClearsOnResync() {
        let store = ChatListStore()
        XCTAssertNil(store.list)
        let list = ChatList(conversations: [
            .init(id: 1, title: "A", updatedAt: Date(timeIntervalSince1970: 1), state: .unread)
        ])
        store.apply(.snapshot(list))
        XCTAssertEqual(store.list, list)
        store.apply(.resync)
        XCTAssertNil(store.list)
    }
}
