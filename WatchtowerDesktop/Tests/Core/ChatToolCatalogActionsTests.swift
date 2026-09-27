import XCTest
@testable import WatchtowerCore

/// Step labels for the write tools a chat turn can call (spec §8): the step
/// block names what was PROPOSED, never claims it happened.
final class ChatToolCatalogActionsTests: XCTestCase {
    func testJiraWriteLabels() {
        XCTAssertEqual(ChatToolCatalog.label(name: "add_jira_comment", args: #"{"key":"ABC-7","body":"x"}"#),
                       "Proposing a comment on ABC-7")
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_jira_issue", args: #"{"key":"ABC-7","status":"Done"}"#),
                       "Proposing ABC-7 → Done")
        XCTAssertEqual(ChatToolCatalog.label(name: "assign_jira_issue", args: #"{"key":"ABC-7","assignee":"me"}"#),
                       "Proposing to assign ABC-7 to me")
        XCTAssertEqual(ChatToolCatalog.label(name: "update_jira_issue", args: #"{"key":"ABC-7","priority":"High"}"#),
                       "Proposing an update to ABC-7")
    }

    func testLocalWriteLabels() {
        XCTAssertEqual(ChatToolCatalog.label(name: "create_idea", args: #"{"essence":"x"}"#), "Saving an idea")
        XCTAssertEqual(ChatToolCatalog.label(name: "create_track", args: #"{"text":"Payments migration"}"#),
                       "Proposing a track: Payments migration")
        XCTAssertEqual(ChatToolCatalog.label(name: "remind_me", args: #"{"remind_at":"2026-10-01T09:00"}"#),
                       "Setting a reminder for 2026-10-01T09:00")
    }

    func testMalformedArgsStillLabelTheTool() {
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_jira_issue", args: "not json"), "Proposing an issue transition")
    }

    func testIcons() {
        XCTAssertEqual(ChatToolCatalog.icon(name: "add_jira_comment"), "text.bubble")
        XCTAssertEqual(ChatToolCatalog.icon(name: "transition_jira_issue"), "arrow.right.circle")
        XCTAssertEqual(ChatToolCatalog.icon(name: "assign_jira_issue"), "person.crop.circle.badge.plus")
        XCTAssertEqual(ChatToolCatalog.icon(name: "update_jira_issue"), "square.and.pencil")
        XCTAssertEqual(ChatToolCatalog.icon(name: "create_idea"), "lightbulb")
        XCTAssertEqual(ChatToolCatalog.icon(name: "create_track"), "binoculars")
        XCTAssertEqual(ChatToolCatalog.icon(name: "remind_me"), "alarm")
    }
}
