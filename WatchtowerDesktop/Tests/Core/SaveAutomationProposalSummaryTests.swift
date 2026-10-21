import GRDB
import XCTest
@testable import WatchtowerCore

/// The Inbox reading pane's summary of a `save_automation` proposal: what it
/// is, where it goes, when it runs and what it may do.
final class SaveAutomationProposalSummaryTests: XCTestCase {
    private func model(_ overrides: [String: Any] = [:]) throws -> SaveAutomationCardModel {
        var args: [String: Any] = [
            "path": "/acme/automations/mail-digest.md", "name": "Mail digest", "slug": "mail-digest",
            "trigger_kind": "schedule", "trigger_spec": ["schedule": "0 9 * * 1-5"],
            "permissions": ["gmail:read@work", "llm:light"], "outputs": ["inbox"],
            "is_new": true, "recipe_text": "---\nname: Mail digest\n---\n"
        ]
        args.merge(overrides) { _, new in new }
        let json = try XCTUnwrap(String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8))
        return SaveAutomationCardModel(action: AgentAction(row: Row([
            "id": 1, "tool": "save_automation", "args_json": json, "status": "pending"
        ])))
    }

    func testSummaryLines() throws {
        let personal = SaveAutomationProposalSummary(model: try model()) { _ in nil }
        XCTAssertEqual(personal.name, "Save automation Mail digest")
        XCTAssertEqual(personal.scope, "Personal")
        XCTAssertEqual(personal.when, "Every weekday at 09:00")
        XCTAssertEqual(try model().whenLine, "Every weekday at 09:00")

        let named = SaveAutomationProposalSummary(model: try model(["workbench_id": 3])) { $0 == 3 ? "acme" : nil }
        XCTAssertEqual(named.scope, "acme")
        let unknown = SaveAutomationProposalSummary(model: try model(["workbench_id": 3])) { _ in nil }
        XCTAssertEqual(unknown.scope, "Workbench #3")
    }

    func testMayLineJoinsTwoAndCountsTheRest() throws {
        let four = try model(["permissions": ["gmail:read@work", "llm:light", "slack:read@acme", "inbox:reply"]])
        XCTAssertEqual(four.permissions, ["gmail:read@work", "llm:light", "slack:read@acme", "inbox:reply"])
        XCTAssertEqual(SaveAutomationProposalSummary(model: four) { _ in nil }.mayLine,
                       "Read mail in work (Gmail), Use the light model and 2 more")
        XCTAssertEqual(SaveAutomationProposalSummary(model: try model()) { _ in nil }.mayLine,
                       "Read mail in work (Gmail), Use the light model")
        let one = try model(["permissions": ["inbox:reply"]])
        XCTAssertEqual(SaveAutomationProposalSummary(model: one) { _ in nil }.mayLine,
                       "Reacts to its own Inbox buttons")
        let none = try model(["permissions": [String]()])
        XCTAssertEqual(SaveAutomationProposalSummary(model: none) { _ in nil }.mayLine, "Nothing")
    }

    /// Open Draft: an edit opens over the saved automation, a new recipe (or
    /// an edit whose automation is gone) as a new draft in its scope.
    func testDraftOpening() throws {
        let acme = Workbench(row: Row(["id": 3, "name": "acme", "folder_path": "/acme/3"]))
        let edit = try model(["is_new": false])
        XCTAssertEqual(SaveProposalDraftOpening(model: edit, savedID: 7, workbenches: []), .existing(7))
        XCTAssertEqual(SaveProposalDraftOpening(model: edit, savedID: nil, workbenches: []), .newDraft(.personal))
        XCTAssertEqual(SaveProposalDraftOpening(model: try model(), savedID: 7, workbenches: []), .newDraft(.personal),
                       "a new recipe never opens over a saved one")
        let workbench = try model(["workbench_id": 3])
        XCTAssertEqual(SaveProposalDraftOpening(model: workbench, savedID: nil, workbenches: [acme]),
                       .newDraft(.forWorkbench(acme)))
        XCTAssertEqual(SaveProposalDraftOpening(model: workbench, savedID: nil, workbenches: []), .workbenchGone(3))
    }
}
