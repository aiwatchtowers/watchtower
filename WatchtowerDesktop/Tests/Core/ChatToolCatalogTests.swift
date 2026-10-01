import XCTest
@testable import WatchtowerCore

final class ChatToolCatalogTests: XCTestCase {
    func testReadToolLabelsCarryTheirSubject() {
        XCTAssertEqual(ChatToolCatalog.label(name: "search_knowledge", args: #"{"queries":["payments rollout","платежи"]}"#),
                       "Searched knowledge: payments rollout, платежи")
        XCTAssertEqual(ChatToolCatalog.label(name: "get_jira_issue", args: #"{"key":"PROJ-123"}"#), "Opened PROJ-123")
        XCTAssertEqual(ChatToolCatalog.label(name: "list_messages", args: #"{"person":"anna"}"#), "Searched Slack: anna")
        XCTAssertEqual(ChatToolCatalog.label(name: "load_skill", args: #"{"name":"triage"}"#), "Loaded skill triage")
    }

    func testWebSearchStep() {
        XCTAssertEqual(ChatToolCatalog.label(name: "WebSearch", args: #"{"query":"swift 6 concurrency"}"#),
                       "Searched the web: swift 6 concurrency")
        XCTAssertEqual(ChatToolCatalog.label(name: "WebSearch", args: "{}"), "Searched the web")
        XCTAssertEqual(ChatToolCatalog.icon(name: "WebSearch"), "globe")
    }

    func testMissingSubjectFallsBack() {
        XCTAssertEqual(ChatToolCatalog.label(name: "get_jira_issue", args: "{}"), "Opened a Jira issue")
        XCTAssertEqual(ChatToolCatalog.label(name: "search_knowledge", args: "not json"), "Searched knowledge")
        XCTAssertEqual(ChatToolCatalog.label(name: "memory_map", args: "{}"), "Read the memory map")
    }

    func testWriteToolsReadAsProposals() {
        XCTAssertEqual(ChatToolCatalog.label(name: "create_jira_issue", args: "{}"), "Proposed: Create a Jira issue")
    }

    func testExternalAndUnknownTools() {
        XCTAssertEqual(ChatToolCatalog.label(name: "confluence:search_pages", args: "{}"), "Used confluence: search pages")
        XCTAssertEqual(ChatToolCatalog.label(name: "brand_new_tool", args: "{}"), "Used brand new tool")
    }

    /// A long argument never becomes a long label.
    func testSubjectIsCapped() throws {
        let data = try JSONSerialization.data(withJSONObject: ["queries": [String(repeating: "x", count: 500)]])
        // Fixture data is always valid UTF-8 (just-serialized JSON).
        // swiftlint:disable:next optional_data_string_conversion
        let label = ChatToolCatalog.label(name: "search_knowledge", args: String(decoding: data, as: UTF8.self))
        XCTAssertLessThanOrEqual(label.count, 120)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testIcons() {
        XCTAssertEqual(ChatToolCatalog.icon(name: "search_knowledge"), "magnifyingglass")
        XCTAssertEqual(ChatToolCatalog.icon(name: "get_jira_issue"), "ticket")
        XCTAssertEqual(ChatToolCatalog.icon(name: "create_target"), "hand.raised")
        XCTAssertEqual(ChatToolCatalog.icon(name: "x:y"), "puzzlepiece.extension")
        XCTAssertEqual(ChatToolCatalog.icon(name: "zzz"), "wrench.and.screwdriver")
    }
}
