import ChatWire
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The relay side of ChatWire's chat models, which the phone adds (`ChatWireKitConformances.swift`, unified chat
/// spec §14): the slice kinds and record names the hub publishes (`TestChatSearch_RecordShape`, …) and the action
/// kinds of `WatchtowerKit/Tests/Fixtures/chat/actions.json` (`TestChatActionsFixture`). The params' wire bytes
/// and the slice payloads are ChatWire's tests (`ChatActionParamsTests`, `ChatSliceMirrorTests`).
final class ChatWireKitConformancesTests: XCTestCase {
    private static let actionsFixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerMobile
        .deletingLastPathComponent()
        .appendingPathComponent("WatchtowerKit/Tests/Fixtures/chat/actions.json")

    func testSliceKindsAndRecordNames() {
        XCTAssertEqual(ChatList.sliceKind.rawValue, "chat_list")
        XCTAssertEqual(ChatFeed.sliceKind.rawValue, "chat_feed")
        XCTAssertEqual(ChatPage.sliceKind.rawValue, "chat_page")
        XCTAssertEqual(ChatSearch.sliceKind.rawValue, "chat_search")
        XCTAssertEqual(ChatList.recordName, "chat_list-main")
        XCTAssertEqual(ChatFeed.recordName(conversationID: 3), "chat_feed-3")
        XCTAssertEqual(ChatPage.recordName(conversationID: 3, beforeMessageID: 10), "chat_page-3-10")
        // Go sources.ChatSearchID("payments") (TestChatSearch_RecordShape).
        XCTAssertEqual(ChatSearch.recordName(query: "payments"), "chat_search-df384ae97c77ad30")
    }

    /// A slice payload decodes through the Kit's SliceMirror as through ChatWire's coder.
    func testSliceMirrorDecodes() throws {
        let json = #"{"conversations":[{"id":1,"title":"x","updated_at":1,"state":"read"}]}"#
        XCTAssertEqual(try ChatList.decode(payload: Data(json.utf8)).conversations.map(\.id), [1])
    }

    func testEveryFixtureCaseNamesAChatKindThatHasParams() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.actionsFixture)) as? [String: Any]
        let cases = try XCTUnwrap(object?["actions"] as? [[String: Any]])
        let kinds = Set(cases.compactMap { $0["kind"] as? String })
        let ours: Set = [
            ChatNewParams.actionKind, ChatTurnParams.actionKind, ChatCancelParams.actionKind,
            ChatFeedRequestParams.actionKind, ChatPageParams.actionKind, ChatSearchParams.actionKind,
            ChatReadParams.actionKind, ChatBranchSelectParams.actionKind, ChatManageParams.actionKind,
            ChatActionAnswerParams.actionKind, ChatEntitySearchParams.actionKind, ChatSkillsListParams.actionKind
        ].reduce(into: Set<String>()) { $0.insert($1.rawValue) }
        XCTAssertEqual(kinds, ours)
        for kind in kinds {
            XCTAssertNotNil(ActionKind(rawValue: kind), kind)
        }
    }

    /// The relay params go through ActionParams' `wireParams()` and back.
    func testWireParamsRoundTrip() throws {
        let params = ChatTurnParams(conversationID: 2, mode: .send, text: "Hi", attachmentIDs: [5])
        let wire = try params.wireParams()
        XCTAssertEqual(wire["conversation_id"], .integer(2))
        XCTAssertEqual(wire["attachment_ids"], .array([.integer(5)]))
        XCTAssertEqual(try ChatTurnParams(wireParams: wire), params)
    }
}
