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

    func testLinearWriteLabels() {
        XCTAssertEqual(ChatToolCatalog.label(name: "add_linear_comment", args: #"{"key":"ENG-7","body":"x"}"#),
                       "Proposing a comment on ENG-7")
        XCTAssertEqual(ChatToolCatalog.label(name: "add_linear_comment", args: "{}"), "Proposing a Linear comment")
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_linear_issue", args: #"{"key":"ENG-7","state_name":"Done","state":"Done"}"#),
                       "Proposing ENG-7 → Done")
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_linear_issue", args: #"{"key":"ENG-7","state_type":"completed"}"#),
                       "Proposing ENG-7 → completed")
        XCTAssertEqual(ChatToolCatalog.label(name: "transition_linear_issue", args: "{}"), "Proposing an issue transition")
        XCTAssertEqual(ChatToolCatalog.label(name: "assign_linear_issue", args: #"{"key":"ENG-7","assignee":"me","assignee_name":"Ada"}"#),
                       "Proposing to assign ENG-7 to Ada")
        XCTAssertEqual(ChatToolCatalog.label(name: "assign_linear_issue", args: #"{"key":"ENG-7","assignee":"me"}"#),
                       "Proposing to assign ENG-7 to me")
        XCTAssertEqual(ChatToolCatalog.label(name: "update_linear_issue", args: #"{"key":"ENG-7"}"#),
                       "Proposing an update to ENG-7")
        XCTAssertEqual(ChatToolCatalog.label(name: "update_linear_issue", args: "{}"), "Proposing a Linear issue update")
        XCTAssertEqual(ChatToolCatalog.label(name: "create_linear_issue", args: "{}"), "Proposed: Create a Linear issue")
    }

    func testLinearIcons() {
        XCTAssertEqual(ChatToolCatalog.icon(name: "add_linear_comment"), "text.bubble")
        XCTAssertEqual(ChatToolCatalog.icon(name: "transition_linear_issue"), "arrow.right.circle")
        XCTAssertEqual(ChatToolCatalog.icon(name: "assign_linear_issue"), "person.crop.circle.badge.plus")
        XCTAssertEqual(ChatToolCatalog.icon(name: "update_linear_issue"), "square.and.pencil")
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
