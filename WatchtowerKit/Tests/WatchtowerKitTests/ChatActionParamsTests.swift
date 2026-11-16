import WatchtowerSync
import XCTest
@testable import WatchtowerKit

/// The chat action params against the Go-written fixture `Tests/Fixtures/chat/actions.json`, which the hub's
/// `TestChatActionsFixture` runs through its handlers (iPhone chat spec §4.5): the Kit encodes each case's params to
/// the bytes the hub accepts. A nil optional is an absent key, so a fixture `null` compares as absent.
final class ChatActionParamsTests: XCTestCase {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures/chat/actions.json")

    private func fixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.fixtureURL)) as? [String: Any])
    }

    private func cases() throws -> [[String: Any]] {
        try XCTUnwrap(fixture()["actions"] as? [[String: Any]])
    }

    private func params(_ name: String) throws -> [String: Any] {
        let found = try XCTUnwrap(cases().first { $0["name"] as? String == name }, name)
        return try XCTUnwrap(found["params"] as? [String: Any])
    }

    /// The fixture's params without `null` members.
    private func stripped(_ object: [String: Any]) -> NSDictionary {
        var out = object
        for (key, value) in object where value is NSNull { out[key] = nil }
        return out as NSDictionary
    }

    private func wire<P: ActionParams>(_ params: P) throws -> NSDictionary {
        let data = try JSONEncoder().encode(try params.wireParams())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func check<P: ActionParams>(_ name: String, _ built: P, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = stripped(try params(name))
        XCTAssertEqual(try wire(built), expected, name, file: file, line: line)
        // The params read back from the bytes are the same value.
        let data = try JSONSerialization.data(withJSONObject: expected)
        let back = try P(wireParams: try JSONDecoder().decode([String: JSONValue].self, from: data))
        XCTAssertEqual(back, built, name, file: file, line: line)
    }

    func testEveryFixtureCaseNamesAChatKindThatHasParams() throws {
        let kinds = Set(try cases().compactMap { $0["kind"] as? String })
        let ours: Set = [
            ChatNewParams.actionKind, ChatTurnParams.actionKind, ChatCancelParams.actionKind,
            ChatFeedRequestParams.actionKind, ChatPageParams.actionKind, ChatSearchParams.actionKind,
            ChatReadParams.actionKind, ChatBranchSelectParams.actionKind, ChatManageParams.actionKind,
            ChatActionAnswerParams.actionKind, ChatEntitySearchParams.actionKind, ChatSkillsListParams.actionKind
        ].reduce(into: Set<String>()) { $0.insert($1.rawValue) }
        XCTAssertEqual(kinds, ours)
        for fixtureCase in try cases() {
            let kind = try XCTUnwrap(fixtureCase["kind"] as? String)
            XCTAssertNotNil(ActionKind(rawValue: kind), kind)
        }
    }

    func testNew() throws {
        try check("new_pinned", ChatNewParams(
            clientKey: "6F9619FF-8B86-4011-B42D-00C04FC964FF",
            routing: ChatRouting(mode: "pinned", provider: "claude", model: "opus")))
        try check("new_auto_in_no_project", ChatNewParams(
            clientKey: "6F9619FF-8B86-4011-B42D-00C04FC96500", routing: ChatRouting(mode: "auto")))
    }

    func testTurn() throws {
        try check("turn_send", ChatTurnParams(
            conversationID: 2, mode: .send, text: "Summarize the rollout", routing: ChatRouting(mode: "auto")))
        try check("turn_regenerate", ChatTurnParams(conversationID: 1, mode: .regenerate, messageID: 2, text: ""))
    }

    func testTheRest() throws {
        try check("cancel", ChatCancelParams(conversationID: 1, turnID: "9B2F6A3C-1D2E-4F50-8A6B-7C8D9E0F1A2B"))
        try check("feed_open", ChatFeedRequestParams(conversationID: 1, purpose: .open))
        try check("feed_prefetch", ChatFeedRequestParams(conversationID: 1, purpose: .prefetch))
        try check("feed_list_retry", ChatFeedRequestParams(conversationID: 0, purpose: .open))
        try check("page", ChatPageParams(conversationID: 1, beforeMessageID: 2))
        try check("search", ChatSearchParams(query: "payments rollout"))
        try check("read", ChatReadParams(conversationID: 1, messageID: 2))
        try check("branch_select", ChatBranchSelectParams(messageID: 1))
        try check("manage_rename", ChatManageParams(conversationID: 2, op: .rename, title: "Rollout notes"))
        try check("manage_pin", ChatManageParams(conversationID: 2, op: .pin))
        try check("action_approve", ChatActionAnswerParams(
            actionID: 1, decision: .approve,
            argsSHA256: "e7b995efa755c5ff3b84d2188b58cb4ae916a59470eb3761df8a814f11763500"))
    }

    func testPickers() throws {
        try check("entity_search_mention", ChatEntitySearchParams(query: "al"))
        try check("entity_search_kinds", ChatEntitySearchParams(query: "pay", kinds: ["channel", "jira"]))
        try check("skills_list", ChatSkillsListParams())
    }

    /// Every fixture case is covered by a test above (a new case must get one).
    func testNoFixtureCaseIsUntested() throws {
        let covered: Set = [
            "new_pinned", "new_auto_in_no_project", "turn_send", "turn_regenerate", "cancel", "feed_open",
            "feed_prefetch", "feed_list_retry", "page", "search", "read", "branch_select", "manage_rename",
            "manage_pin", "action_approve", "entity_search_mention", "entity_search_kinds", "skills_list"
        ]
        XCTAssertEqual(Set(try cases().compactMap { $0["name"] as? String }), covered)
    }

    /// The hub counts runes, not grapheme clusters: a family emoji is one Character and seven scalars.
    func testTextCapCountsUnicodeScalars() {
        XCTAssertEqual(ChatLimits.maxTextScalars, 32000)
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(family.count, 1)
        XCTAssertEqual(ChatLimits.textLength(family), 7)
        XCTAssertTrue(ChatLimits.textFits(String(repeating: "a", count: 32000)))
        XCTAssertFalse(ChatLimits.textFits(String(repeating: "a", count: 32001)))
        XCTAssertFalse(ChatLimits.textFits(String(repeating: family, count: 4572))) // 4572 × 7 = 32004, 4572 Characters
    }

    func testChatReasonsMapAndAnOldCodeStaysNil() {
        XCTAssertEqual(ActionReason(rawValue: "conversation_busy"), .conversationBusy)
        XCTAssertEqual(ActionReason(rawValue: "attachment_missing"), .attachmentMissing)
        XCTAssertEqual(ActionReason(rawValue: "changed"), .changed)
        XCTAssertEqual(ChatActionReason(.conversationBusy), .conversationBusy)
        XCTAssertEqual(ChatActionReason(.attachmentMissing), .attachmentMissing)
        XCTAssertEqual(ChatActionReason(.changed), .actionChanged)
        XCTAssertEqual(ChatActionReason(.notSupported), .notSupported)
        XCTAssertNil(ChatActionReason(.writeFailed))
        XCTAssertNil(ChatActionReason(nil))
    }
}
