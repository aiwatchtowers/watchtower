import GRDB
import XCTest
@testable import WatchtowerCore

/// The `save_automation` card over the args `Normalize` pinned
/// (`internal/automations/authoring/save.go`).
final class SaveAutomationCardModelTests: XCTestCase {
    private func action(_ overrides: [String: Any] = [:]) throws -> AgentAction {
        var args: [String: Any] = [
            "scope": "personal", "path": "/acme/automations/mail-digest.md", "name": "Mail digest",
            "trigger_kind": "schedule", "trigger_spec": ["schedule": "0 9 * * 1-5"],
            "permissions": ["gmail:read@work", "llm:light"], "outputs": ["inbox"],
            "budget_tokens": 40000, "budget_minutes": 5, "approval_hash": "h2",
            "widening": ["gmail:read@work"], "existing_content_hash": "c1",
            "previous_recipe_text": "---\nname: Mail digest\n---\nold line\n", "is_new": false,
            "recipe_text": "---\nname: Mail digest\n---\nnew line\n", "slug": "mail-digest",
            "reason": "skip newsletters", "dry_run_summary": "Read 17 messages, 4 need a reply."
        ]
        args.merge(overrides) { _, new in new }
        let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8))
        return AgentAction(row: Row([
            "id": 1, "tool": "save_automation", "args_json": json, "reason": "skip newsletters",
            "status": "pending", "turn_id": "t1"
        ]))
    }

    func testTitleAndTrigger() throws {
        let model = SaveAutomationCardModel(action: try action())
        XCTAssertEqual(model.title, "Save automation Mail digest")
        XCTAssertEqual(model.lines.first, "When: Every weekday at 09:00")
    }

    func testWideningEntriesMarked() throws {
        let model = SaveAutomationCardModel(action: try action())
        XCTAssertTrue(model.lines.contains("+ gmail:read@work — Read mail in work (Gmail)"), "\(model.lines)")
        XCTAssertTrue(model.lines.contains("llm:light — Use the light model"), "\(model.lines)")
        XCTAssertTrue(model.lines.contains("output: inbox — Put cards in your Inbox"), "\(model.lines)")
    }

    func testDiffForEditNilForNew() throws {
        let edit = SaveAutomationCardModel(action: try action())
        let diff = try XCTUnwrap(edit.diff)
        XCTAssertTrue(diff.lines.contains(.removed("old line")))
        XCTAssertTrue(diff.lines.contains(.added("new line")))

        let new = SaveAutomationCardModel(action: try action(["is_new": true, "previous_recipe_text": ""]))
        XCTAssertNil(new.diff)
    }

    func testDryRunSummaryLabelled() throws {
        let model = SaveAutomationCardModel(action: try action())
        XCTAssertEqual(model.dryRunSummary, "Assistant's dry-run summary: Read 17 messages, 4 need a reply.")
        XCTAssertNil(SaveAutomationCardModel(action: try action(["dry_run_summary": " "])).dryRunSummary)
    }

    func testBudgetLine() throws {
        let model = SaveAutomationCardModel(action: try action())
        XCTAssertEqual(model.lines.last, "Budget: 40,000 tokens · 5 min")
    }
}
