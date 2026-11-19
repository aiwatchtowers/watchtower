import ChatWire
import XCTest

/// The feed and list stores (unified chat spec §5.4): a snapshot replaces, an upsert replaces or appends by id, a
/// resync keeps what is shown, marked stale, until the next snapshot; gone empties the feed.
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

    func testFeedStoreResyncKeepsTheFeedStaleUntilSnapshot() {
        let store = ChatFeedStore()
        store.apply(.resync)
        XCTAssertNil(store.feed)
        XCTAssertFalse(store.isStale, "nothing shown, nothing stale")

        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi")])))
        store.apply(.resync)
        XCTAssertEqual(store.feed?.messages.map(\.text), ["Hi"], "the last feed stays on screen")
        XCTAssertTrue(store.isStale)

        // Updates in the gap still apply to the kept feed.
        store.apply(.messageUpsert(message(2, "Hel")))
        let renamed = ChatFeed.Conversation(id: 3, title: "Renamed")
        store.apply(.conversation(renamed))
        XCTAssertEqual(store.feed?.messages.map(\.text), ["Hi", "Hel"])
        XCTAssertEqual(store.feed?.conversation.title, "Renamed")
        XCTAssertTrue(store.isStale)

        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi"), message(2, "Hello")])))
        XCTAssertEqual(store.feed?.messages.map(\.text), ["Hi", "Hello"])
        XCTAssertFalse(store.isStale)
    }

    func testFeedStoreGoneEmptiesUntilTheConversationComesBack() {
        let store = ChatFeedStore()
        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi")])))
        store.apply(.resync)
        store.apply(.gone)
        XCTAssertNil(store.feed)
        XCTAssertTrue(store.isGone)
        XCTAssertFalse(store.isStale)
        store.apply(.messageUpsert(message(2, "late")))
        XCTAssertNil(store.feed)

        store.apply(.snapshot(ChatFeed(conversation: conversation, messages: [message(1, "Hi")])))
        XCTAssertFalse(store.isGone)
        XCTAssertEqual(store.feed?.messages.map(\.id), [1])
    }

    func testListStoreKeepsTheListStaleOnResync() {
        let store = ChatListStore()
        XCTAssertNil(store.list)
        let list = ChatList(conversations: [
            .init(id: 1, title: "A", updatedAt: Date(timeIntervalSince1970: 1), state: .unread)
        ])
        store.apply(.snapshot(list))
        XCTAssertFalse(store.isStale)
        store.apply(.resync)
        XCTAssertEqual(store.list, list)
        XCTAssertTrue(store.isStale)
        let fresh = ChatList(conversations: [])
        store.apply(.snapshot(fresh))
        XCTAssertEqual(store.list, fresh)
        XCTAssertFalse(store.isStale)
    }
}
