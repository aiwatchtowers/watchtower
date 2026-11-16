/// The AI chat slice kinds (iPhone chat spec §4.6) decoded from the frozen
/// fixtures under `WatchtowerKit/Tests/Fixtures/workbench/chat_*.json`,
/// which the hub's Go sources are pinned to (`TestChatList_PayloadMatchesKitFixture`,
/// `TestChatFeed_PayloadMatchesKitFixture`, `TestChatPage_SixtyBeforeID`,
/// `TestChatSearch_RecordShape`).
import WatchtowerKit
import WatchtowerSync
import XCTest

final class ChatSliceMirrorTests: XCTestCase {
    private static let kitTests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.kitTests.appendingPathComponent("Fixtures/workbench/\(name).json"))
    }

    func testKinds() {
        XCTAssertEqual(ChatList.sliceKind.rawValue, "chat_list")
        XCTAssertEqual(ChatFeed.sliceKind.rawValue, "chat_feed")
        XCTAssertEqual(ChatPage.sliceKind.rawValue, "chat_page")
        XCTAssertEqual(ChatSearch.sliceKind.rawValue, "chat_search")
    }

    func testChatListDecodes() throws {
        let list = try ChatList.decode(payload: try fixture("chat_list"))
        XCTAssertEqual(list.conversations.count, 3)
        let first = list.conversations[0]
        XCTAssertEqual(first.id, 3)
        XCTAssertTrue(first.pinned)
        XCTAssertEqual(first.state, .answering)
        XCTAssertEqual(first.project, ChatList.Project(id: 1, name: "Acme launch"))
        XCTAssertEqual(first.leaseOwner, "hub")
        XCTAssertEqual(first.lastLine, "The rollout slipped to Friday.")
        XCTAssertEqual(first.updatedAt, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertEqual(list.conversations[1].state, .waiting)
        XCTAssertNil(list.conversations[1].project)
        XCTAssertEqual(list.conversations[2].updatedAt, Date(timeIntervalSince1970: 1_700_000_100.5))
        XCTAssertEqual(list.models[0], ChatList.Model(provider: "claude", model: "opus", displayName: "Claude", images: true, pdf: true))
        XCTAssertFalse(list.models[1].pdf)
        XCTAssertEqual(list.projects.map(\.name), ["Acme launch"])
        XCTAssertNil(list.error)
        XCTAssertEqual(ChatList.recordName, "chat_list-main")
    }

    func testChatListErrorAndUnknownState() throws {
        let json = #"{"conversations":[{"id":1,"title":"x","pinned":false,"updated_at":1,"state":"thinking","last_line":""}],"#
            + #""projects":[],"models":[],"error":"read_failed"}"#
        let list = try ChatList.decode(payload: Data(json.utf8))
        XCTAssertEqual(list.error, "read_failed")
        XCTAssertFalse(list.conversations[0].state.isKnown)
    }

    func testChatFeedDecodes() throws {
        let feed = try ChatFeed.decode(payload: try fixture("chat_feed"))
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
        XCTAssertEqual(ChatFeed.recordName(conversationID: 3), "chat_feed-3")
    }

    func testChatPageDecodes() throws {
        let page = try ChatPage.decode(payload: try fixture("chat_page"))
        XCTAssertEqual(page.messages.map(\.id), [4, 5])
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(ChatPage.recordName(conversationID: 3, beforeMessageID: 10), "chat_page-3-10")
    }

    func testChatSearchDecodes() throws {
        let search = try ChatSearch.decode(payload: try fixture("chat_search"))
        XCTAssertEqual(search.query, "payments")
        XCTAssertEqual(search.hits[0].messageID, 11)
        XCTAssertTrue(search.hits[0].snippet.contains(ChatSearch.markStart + "payments" + ChatSearch.markEnd))
        XCTAssertEqual(search.hits[0].date, Date(timeIntervalSince1970: 1_700_000_020))
        XCTAssertNil(search.hits[1].messageID)
        // Go sources.ChatSearchID("payments") (TestChatSearch_RecordShape).
        XCTAssertEqual(ChatSearch.recordName(query: "payments"), "chat_search-df384ae97c77ad30")
    }
}
