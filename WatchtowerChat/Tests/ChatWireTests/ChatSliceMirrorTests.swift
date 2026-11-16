/// The AI chat slice payloads (iPhone chat spec §4.6) decoded from the frozen
/// fixtures under `WatchtowerKit/Tests/Fixtures/workbench/chat_*.json`,
/// which the hub's Go sources are pinned to (`TestChatList_PayloadMatchesKitFixture`,
/// `TestChatFeed_PayloadMatchesKitFixture`, `TestChatPage_SixtyBeforeID`,
/// `TestChatSearch_RecordShape`). The slice kinds and record names are the
/// phone's (`ChatWireKitConformancesTests`).
import ChatWire
import XCTest

final class ChatSliceMirrorTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: ChatWireFixtures.kitFixture("workbench/\(name).json"))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try ChatWireCoder.makeDecoder().decode(type, from: data)
    }

    func testChatListDecodes() throws {
        let list = try decode(ChatList.self, try fixture("chat_list"))
        XCTAssertEqual(list.conversations.count, 3)
        let first = list.conversations[0]
        XCTAssertEqual(first.id, 3)
        XCTAssertTrue(first.pinned)
        XCTAssertEqual(first.state, .answering)
        XCTAssertEqual(first.project, ChatList.Project(id: 1, name: "Acme launch"))
        XCTAssertEqual(first.leaseOwner, "hub")
        XCTAssertEqual(first.turnID, "turn-2", "the running turn of an answering chat")
        XCTAssertNil(list.conversations[1].turnID)
        XCTAssertEqual(first.lastLine, "The rollout slipped to Friday.")
        XCTAssertEqual(first.updatedAt, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(list.conversations[1].state, .waiting)
        XCTAssertNil(list.conversations[1].project)
        XCTAssertEqual(list.conversations[2].updatedAt, Date(timeIntervalSince1970: 1_700_000_100.5))
        XCTAssertEqual(list.models[0], ChatList.Model(provider: "claude", model: "opus", displayName: "Claude", images: true, pdf: true))
        XCTAssertFalse(list.models[1].pdf)
        XCTAssertEqual(list.projects.map(\.name), ["Acme launch"])
        XCTAssertNil(list.error)
    }

    func testChatListErrorAndUnknownState() throws {
        let json = #"{"conversations":[{"id":1,"title":"x","pinned":false,"updated_at":1,"state":"thinking","last_line":""}],"#
            + #""projects":[],"models":[],"error":"read_failed"}"#
        let list = try decode(ChatList.self, Data(json.utf8))
        XCTAssertEqual(list.error, "read_failed")
        XCTAssertFalse(list.conversations[0].state.isKnown)
    }

    func testChatFeedDecodes() throws {
        let feed = try decode(ChatFeed.self, try fixture("chat_feed"))
        let conv = feed.conversation
        XCTAssertEqual(conv.id, 3)
        XCTAssertEqual(conv.routing, ChatFeed.Routing(mode: "pinned", provider: "claude", model: "opus"))
        XCTAssertEqual(conv.actualModel, "opus")
        XCTAssertEqual(conv.liveSlackSince, 11)
        XCTAssertEqual(conv.lease, ChatFeed.Lease(owner: "hub", turnID: "turn-2", waitingSlot: false))
        XCTAssertTrue(feed.hasMore)
        XCTAssertEqual(feed.messages.map(\.id), [10, 11, 12, 13])
        XCTAssertEqual(feed.messages[0].attachments, [ChatFeed.Attachment(id: 5, name: "plan.pdf", mime: "application/pdf", size: 2048)])
        let answer = feed.messages[1]
        XCTAssertEqual(answer.siblings, ChatFeed.Siblings(index: 2, count: 2, ids: [9, 11]))
        XCTAssertEqual(answer.siblings.neighbour(-1), 9)
        XCTAssertNil(answer.siblings.neighbour(1))
        XCTAssertEqual(feed.messages[0].siblings.ids, [])
        XCTAssertEqual(answer.steps[0].outcome, .succeeded)
        XCTAssertEqual(answer.steps[0].sources[0].url, "https://example.com/p1")
        XCTAssertEqual(answer.steps[1].outcome, .running)
        let last = feed.messages[3]
        XCTAssertEqual(last.status, "partial")
        XCTAssertEqual(last.errorCode, "session_lost")
        XCTAssertEqual(last.errorMessage, "The session ended.")
        XCTAssertTrue(last.textCut)
        XCTAssertEqual(feed.artifacts[0].content, "# Rollout plan\n\nFriday, 10:00.")
        XCTAssertNil(feed.artifacts[1].content)
        XCTAssertTrue(feed.artifacts[1].contentCut)
        let action = feed.actions[0]
        XCTAssertEqual(action.id, 7)
        XCTAssertEqual(action.status, "pending")
        XCTAssertEqual(action.argsSHA256.count, 64)
        XCTAssertEqual(action.reason, "Tell the team about the new date")
    }

    func testChatPageDecodes() throws {
        let page = try decode(ChatPage.self, try fixture("chat_page"))
        XCTAssertEqual(page.messages.map(\.id), [4, 5])
        XCTAssertFalse(page.hasMore)
    }

    func testChatSearchDecodes() throws {
        let search = try decode(ChatSearch.self, try fixture("chat_search"))
        XCTAssertEqual(search.query, "payments")
        XCTAssertEqual(search.hits[0].messageID, 11)
        XCTAssertTrue(search.hits[0].snippet.contains(ChatSearch.markStart + "payments" + ChatSearch.markEnd))
        XCTAssertEqual(search.hits[0].date, Date(timeIntervalSince1970: 1_700_000_020))
        XCTAssertNil(search.hits[1].messageID)
    }
}
