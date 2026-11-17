import GRDB
import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

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

    /// The pane draws the feed's words (Go `SummarizeSaveAutomation`, its
    /// cases in `internal/inboxfeed`): the title, then each "<label>:
    /// <value>" line split at its first ": ".
    func testSummaryDrawsTheFeedsLines() {
        let summary = SaveAutomationProposalSummary(approval: TestInboxFeeds.approval(
            title: "Save automation Mail digest",
            summary: ["For: Personal", "When: Every weekday at 09:00",
                      "It may: Read mail in work (Gmail): inbox, Use the light model"]))
        XCTAssertEqual(summary.name, "Save automation Mail digest")
        XCTAssertEqual(summary.lines, [
            .init(label: "For", value: "Personal"),
            .init(label: "When", value: "Every weekday at 09:00"),
            .init(label: "It may", value: "Read mail in work (Gmail): inbox, Use the light model")
        ])
    }

    func testALineWithoutALabelKeepsItsText() {
        let summary = SaveAutomationProposalSummary(approval: TestInboxFeeds.approval(title: "x", summary: ["Nothing"]))
        XCTAssertEqual(summary.lines, [.init(label: "", value: "Nothing")])
    }

    func testNoFeedDrawsNothing() {
        let summary = SaveAutomationProposalSummary(approval: nil)
        XCTAssertEqual(summary.name, "")
        XCTAssertEqual(summary.lines, [])
    }

    func testWhenLineOfTheDraftModel() throws {
        XCTAssertEqual(try model().whenLine, "Every weekday at 09:00")
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
