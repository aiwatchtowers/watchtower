import ChatWire
import XCTest

/// The chat.sock subscription events as Go `chatengine.Event` writes them (`internal/chatengine/subscribe.go`).
final class ChatSocketEventTests: XCTestCase {
    private func event(_ json: String) throws -> ChatSocketEvent {
        try ChatWireCoder.makeDecoder().decode(ChatSocketEvent.self, from: Data(json.utf8))
    }

    private let feed = #"{"conversation":{"id":3,"title":"T"},"messages":[{"id":4,"role":"user","text":"a","created_at":1}]}"#

    func testFeedEvents() throws {
        let snapshot = try event(#"{"event":"snapshot","subscription":"s1","conversation_id":3,"snapshot":\#(feed)}"#)
        XCTAssertEqual(snapshot.subscription, "s1")
        guard case .snapshot(let got)? = snapshot.feedUpdate else { return XCTFail("not a snapshot") }
        XCTAssertEqual(got.messages.map(\.id), [4])

        let upsert = try event(#"{"event":"message_upsert","subscription":"s1","message":{"id":5,"role":"assistant","text":"b","created_at":2}}"#)
        guard case .messageUpsert(let message)? = upsert.feedUpdate else { return XCTFail("not an upsert") }
        XCTAssertEqual(message.id, 5)

        let meta = try event(#"{"event":"conversation_update","subscription":"s1","conversation":{"id":3,"title":"New"}}"#)
        guard case .conversation(let conversation)? = meta.feedUpdate else { return XCTFail("not a meta update") }
        XCTAssertEqual(conversation.title, "New")

        guard case .resync? = try event(#"{"event":"resync","subscription":"s1","conversation_id":3}"#).feedUpdate else {
            return XCTFail("not a resync")
        }
        XCTAssertNil(try event(#"{"event":"typing","subscription":"s1"}"#).feedUpdate)
    }

    /// A conversation snapshot without a feed: the conversation was deleted.
    func testASnapshotWithoutAFeedIsGone() throws {
        guard case .gone? = try event(#"{"event":"snapshot","subscription":"s1","conversation_id":3}"#).feedUpdate else {
            return XCTFail("not gone")
        }
    }

    func testListEvents() throws {
        let list = #"{"conversations":[{"id":1,"title":"A","updated_at":1,"state":"unread"}],"projects":[],"models":[]}"#
        for name in ["snapshot", "list_update"] {
            let update = try event(#"{"event":"\#(name)","subscription":"s2","list":\#(list)}"#)
            guard case .snapshot(let got)? = update.listUpdate else { return XCTFail(name) }
            XCTAssertEqual(got.conversations.map(\.id), [1])
            XCTAssertNil(update.feedUpdate, "a list snapshot is not a feed event")
        }
        guard case .resync? = try event(#"{"event":"resync","subscription":"s2"}"#).listUpdate else {
            return XCTFail("not a resync")
        }
    }
}
