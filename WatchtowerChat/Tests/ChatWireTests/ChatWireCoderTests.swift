import ChatWire
import WatchtowerSync
import XCTest

/// ChatWireCoder is RelayCoder's settings exactly: the phone's relay records and chat.sock read one model.
final class ChatWireCoderTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let kind: String
        let params: ChatJSONValue
    }

    private struct Fixture: Decodable {
        let actions: [Case]
    }

    /// Every params fixture case encoded by both coders gives the same bytes.
    func testWireCoderMatchesRelayCoder() throws {
        let data = try Data(contentsOf: ChatWireFixtures.kitFixture("chat/actions.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertFalse(fixture.actions.isEmpty)
        for item in fixture.actions {
            let params = try JSONEncoder().encode(item.params)
            let ours = try encodedTwice(kind: item.kind, params: params)
            XCTAssertEqual(ours.wire, ours.relay, item.name)
        }
    }

    func testDatesAreUnixSeconds() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_100.5)
        XCTAssertEqual(
            try ChatWireCoder.makeEncoder().encode(["at": date]),
            try RelayCoder.makeEncoder().encode(["at": date])
        )
        XCTAssertEqual(try ChatWireCoder.makeDecoder().decode([String: Date].self, from: Data(#"{"at":7}"#.utf8))["at"],
                       Date(timeIntervalSince1970: 7))
    }

    private func encodedTwice(kind: String, params: Data) throws -> (wire: Data, relay: Data) {
        switch kind {
        case "chat_new": return try both(ChatNewParams.self, params)
        case "chat_turn": return try both(ChatTurnParams.self, params)
        case "chat_cancel": return try both(ChatCancelParams.self, params)
        case "chat_feed_request": return try both(ChatFeedRequestParams.self, params)
        case "chat_page": return try both(ChatPageParams.self, params)
        case "chat_search": return try both(ChatSearchParams.self, params)
        case "chat_read": return try both(ChatReadParams.self, params)
        case "chat_branch_select": return try both(ChatBranchSelectParams.self, params)
        case "chat_manage": return try both(ChatManageParams.self, params)
        case "chat_action_answer": return try both(ChatActionAnswerParams.self, params)
        case "chat_entity_search": return try both(ChatEntitySearchParams.self, params)
        case "chat_skills_list": return try both(ChatSkillsListParams.self, params)
        default:
            XCTFail("no params type for \(kind)")
            return (Data(), Data())
        }
    }

    private func both<P: Codable>(_ type: P.Type, _ params: Data) throws -> (wire: Data, relay: Data) {
        let value = try ChatWireCoder.makeDecoder().decode(type, from: params)
        return (try ChatWireCoder.makeEncoder().encode(value), try RelayCoder.makeEncoder().encode(value))
    }
}
