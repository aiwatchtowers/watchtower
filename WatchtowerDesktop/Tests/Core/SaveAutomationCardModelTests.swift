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
        XCTAssertEqual(model.lines.prefix(2), ["File: mail-digest.md (replaces the saved one)",
                                               "When: Every weekday at 09:00"])
    }

    /// J1: approving a NEW recipe confirms a script the owner must be able to
    /// see — the card carries the whole text; an edit shows the diff instead.
    func testNewRecipeDisclosesTheWholeText() throws {
        let text = "---\nname: Mail digest\n---\nnew line\n"
        let new = SaveAutomationCardModel(action: try action(["is_new": true, "previous_recipe_text": "",
                                                              "recipe_text": text]))
        XCTAssertEqual(new.newRecipeText, text)
        XCTAssertEqual(new.lines.first, "File: mail-digest.md (new)")
        XCTAssertNil(SaveAutomationCardModel(action: try action()).newRecipeText, "an edit shows the diff")
        XCTAssertEqual(SaveAutomationCardModel.recipeDisclosureTitle(text), "Show the whole recipe (4 lines)")
        XCTAssertEqual(SaveAutomationCardModel.recipeDisclosureTitle("one"), "Show the whole recipe (1 line)")
    }

    /// Every hashed field (D26) is on the card: missed and concurrency too.
    func testMissedAndConcurrencyLines() throws {
        let model = SaveAutomationCardModel(action: try action(["missed": "skip", "concurrency": 2]))
        XCTAssertTrue(model.lines.contains("Missed: skip a time the Mac was asleep"), "\(model.lines)")
        XCTAssertTrue(model.lines.contains("Concurrency: up to 2 runs at a time"), "\(model.lines)")
        let defaults = SaveAutomationCardModel(action: try action(["missed": "run_once", "concurrency": 1]))
        XCTAssertTrue(defaults.lines.contains("Missed: run once when the Mac wakes"), "\(defaults.lines)")
        XCTAssertTrue(defaults.lines.contains("Concurrency: one run at a time"), "\(defaults.lines)")
    }

    /// The editor chat ties the card to the Draft panel: a text that differs
    /// from the newest draft shown warns; no draft (main chat) never warns.
    func testDiffersFromDraft() throws {
        let model = SaveAutomationCardModel(action: try action())
        XCTAssertFalse(model.differsFromDraft(nil))
        XCTAssertFalse(model.differsFromDraft("---\nname: Mail digest\n---\nnew line\n"))
        XCTAssertTrue(model.differsFromDraft("---\nname: Mail digest\n---\nanother line\n"))
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

    /// Approving the card confirms the recipe (spec §11) and never enables
    /// it: the note after the save says exactly that.
    func testAppliedNoteSaysConfirmedNotEnabled() throws {
        XCTAssertEqual(SaveAutomationCardModel(action: try action(["is_new": true])).appliedNote,
                       "Saved and confirmed. It's off until you turn it on in Automations.")
        XCTAssertEqual(SaveAutomationCardModel(action: try action()).appliedNote,
                       "Saved and confirmed. Whether it runs is still set by its switch in Automations.")
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
