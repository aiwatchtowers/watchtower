import ChatWire
import DesignKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport
import XCTest

/// The Go feed's approval text and target button states equal what the
/// Mac's app-target views draw today, over the shared fixtures in
/// `internal/inboxfeed/testdata` (Go runs them in
/// `TestApprovalText_SharedCases` and `TestTargetState_SharedCases`):
/// - `approval_text_cases.json`: the native approval card's title, body
///   lines and edit (`MacAgentActionCard.title`/`summaryLines` over
///   ChatWire's `Actions/` rules, the Slack and connector branches of its
///   body); `SaveAutomationProposalPane`
///   draws Go's own lines since Task 11d-b, so its case checks they come
///   through the pane's split unchanged;
/// - `target_button_cases.json`: an Inbox target button's state, Go's since
///   Task 11d-b: the Mac draws every state Go sends
///   (`TargetButtonStateResolver.state` over `InboxTargetButton`).
final class ApprovalTextParityTests: XCTestCase {
    /// …/internal/inboxfeed/testdata, from …/WatchtowerDesktop/Tests/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/inboxfeed/testdata")

    private struct TextCase: Decodable {
        struct Expect: Decodable {
            struct DiffLine: Decodable, Equatable {
                let kind: String
                let text: String
            }

            let title: String
            let summary: [String]
            let editOnMac: Bool
            let disclosure: String
            let recipeText: String
            let diff: [DiffLine]

            enum CodingKeys: String, CodingKey {
                case title, summary, disclosure, diff
                case editOnMac = "edit_on_mac"
                case recipeText = "recipe_text"
            }
        }

        let name: String
        let tool: String
        let args: String
        let result: String
        /// The row's status; nil reads as pending.
        let status: String?
        let workbenchNames: [String: String]
        let expect: Expect

        enum CodingKeys: String, CodingKey {
            case name, tool, args, result, status, expect
            case workbenchNames = "workbench_names"
        }
    }

    func testApprovalTextMatchesGo() throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("approval_text_cases.json"))
        let cases = try JSONDecoder().decode([TextCase].self, from: data)
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for item in cases {
            let action = AgentAction(row: Row([
                "id": 1, "tool": item.tool, "args_json": item.args, "result_json": item.result, "status": item.status ?? "pending"
            ]))
            let text = Self.cardText(action, expect: item.expect) { item.workbenchNames[String($0)] }
            XCTAssertEqual(text.title, item.expect.title, "\(item.name): title")
            XCTAssertEqual(text.summary, item.expect.summary, "\(item.name): summary")
            XCTAssertEqual(text.editOnMac, item.expect.editOnMac, "\(item.name): edit on Mac")
            let disclosure = Self.disclosure(action)
            XCTAssertEqual(disclosure.title, item.expect.disclosure, "\(item.name): disclosure")
            XCTAssertEqual(disclosure.recipe, item.expect.recipeText, "\(item.name): recipe text")
            XCTAssertEqual(disclosure.diff, item.expect.diff, "\(item.name): diff")
        }
    }

    /// A proposal's card as the Inbox reading pane draws it: a pending
    /// save_automation as `SaveAutomationProposalPane` (its name, then For /
    /// When / It may, Open Draft), else `MacAgentActionCard` (its title; a
    /// save_automation's `SaveAutomationCardDetails` text: the scope line,
    /// the model's lines, the dry-run summary; a connector call's connector,
    /// tool and input with Edit Input; a Slack send's recipient and text
    /// with its editor; any other tool's summary lines). The workbench name
    /// comes from the app's workbench list, `WorkbenchQueries.summaries`
    /// (the `projects` rows), as the fixture's names stand for.
    private static func cardText(
        _ action: AgentAction, expect: TextCase.Expect, workbenchName: @escaping (Int64) -> String?
    ) -> (title: String, summary: [String], editOnMac: Bool) {
        if action.tool == SaveAutomationCardModel.tool, !action.isPending {
            let model = SaveAutomationCardModel(action: action)
            return (model.title, [model.scopeLine(workbenchName: workbenchName)] + model.lines
                + (model.dryRunSummary.map { [$0] } ?? []), false)
        }
        if action.tool == SaveAutomationCardModel.tool {
            // The pane draws the feed's approval (Go's words): split into
            // its label and value rows, then read back.
            var approval = TestInboxFeeds.approval(title: expect.title, summary: expect.summary)
            approval.editOnMac = expect.editOnMac
            let summary = SaveAutomationProposalSummary(approval: approval)
            return (summary.name, summary.lines.map { "\($0.label): \($0.value)" }, approval.editOnMac)
        }
        let title = MacAgentActionCard.title(for: action)
        if let connector = ConnectorCallProposal(action: action) {
            return (title, ["Connector: \(connector.server)", "Tool: \(connector.toolName)", connector.inputJSON], true)
        }
        if SlackSendProposal(action: action) != nil, let lines = ActionSummaryLines.slackSummaryLines(for: action) {
            return (title, lines, true)
        }
        return (title, MacAgentActionCard.summaryLines(for: action), false)
    }

    /// SaveAutomationCardDetails' recipe disclosure on a save_automation
    /// past pending: a new recipe's `RecipeTextDisclosure` (its title and
    /// text), an edit's "Show changes" with the diff lines, or "No change to
    /// the recipe text" (disabled, no lines). None anywhere else.
    private static func disclosure(
        _ action: AgentAction
    ) -> (title: String, recipe: String, diff: [TextCase.Expect.DiffLine]) {
        guard action.tool == SaveAutomationCardModel.tool, !action.isPending else { return ("", "", []) }
        let model = SaveAutomationCardModel(action: action)
        if let text = model.newRecipeText { return (SaveAutomationCardModel.recipeDisclosureTitle(text), text, []) }
        guard let diff = model.diff else { return ("", "", []) }
        if diff.isIdentical { return ("No change to the recipe text", "", []) }
        let lines = diff.lines.map { line -> TextCase.Expect.DiffLine in
            switch line {
            case let .same(text): .init(kind: "same", text: text)
            case let .added(text): .init(kind: "added", text: text)
            case let .removed(text): .init(kind: "removed", text: text)
            }
        }
        return ("Show changes", "", lines)
    }

    private struct TargetCase: Decodable {
        struct Proposal: Decodable {
            let status: String
            let decidedAt: String
            let dismissedAt: String
            let error: String

            enum CodingKeys: String, CodingKey {
                case status, error
                case decidedAt = "decided_at"
                case dismissedAt = "dismissed_at"
            }
        }

        struct Expect: Decodable {
            let detail: String
            let note: String
        }

        let name: String
        let now: String
        let proposal: Proposal?
        let taskExists: Bool
        let expect: Expect

        enum CodingKeys: String, CodingKey {
            case name, now, proposal, expect
            case taskExists = "task_exists"
        }
    }

    func testTargetButtonStateMatchesGo() throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("target_button_cases.json"))
        let cases = try JSONDecoder().decode([TargetCase].self, from: data)
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let now = try XCTUnwrap(AutomationDates.parse(item.now), item.name)
            // Go's state as the feed sends it; a creating one carries its `until`.
            let until = item.expect.detail == "creating" ? now.addingTimeInterval(1) : nil
            let button = InboxTargetButton(detail: item.expect.detail, note: item.expect.note, until: until)
            let (detail, note) = Self.wire(TargetButtonStateResolver.state(button, now: now))
            XCTAssertEqual(detail, item.expect.detail, "\(item.name): state")
            XCTAssertEqual(note, item.expect.note, "\(item.name): note")
        }
    }

    /// The feed's CardAction detail and note for a target button state.
    private static func wire(_ state: ArtifactTargetButtonState) -> (String, String) {
        switch state {
        case .idle: ("idle", "")
        case .waiting: ("waiting", "")
        case .creating: ("creating", "")
        case .stuck: ("stuck", "")
        case .created: ("created", "")
        case let .failed(message): ("failed", message)
        case let .proposeError(message): ("propose_error", message)
        }
    }
}
