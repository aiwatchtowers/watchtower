import DesignKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import XCTest

/// The Go feed's approval text and target button states equal what the
/// Mac's app-target views draw today, over the shared fixtures in
/// `internal/inboxfeed/testdata` (Go runs them in
/// `TestApprovalText_SharedCases` and `TestTargetState_SharedCases`):
/// - `approval_text_cases.json`: the native approval card's title, body
///   lines and edit (`AgentActionCardView.title`/`summaryLines`, the Slack
///   and connector branches of its body, `SaveAutomationProposalPane`);
/// - `target_button_cases.json`: an Inbox target button's state
///   (`TargetButtonStateResolver.state`) from its newest proposal.
final class ApprovalTextParityTests: XCTestCase {
    /// …/internal/inboxfeed/testdata, from …/WatchtowerDesktop/Tests/<this file>.
    private static let testdata = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // …/Tests
        .deletingLastPathComponent()  // …/WatchtowerDesktop
        .deletingLastPathComponent()  // the repository
        .appendingPathComponent("internal/inboxfeed/testdata")

    private struct TextCase: Decodable {
        struct Expect: Decodable {
            let title: String
            let summary: [String]
            let editOnMac: Bool

            enum CodingKeys: String, CodingKey {
                case title, summary
                case editOnMac = "edit_on_mac"
            }
        }

        let name: String
        let tool: String
        let args: String
        let result: String
        let workbenchNames: [String: String]
        let expect: Expect

        enum CodingKeys: String, CodingKey {
            case name, tool, args, result, expect
            case workbenchNames = "workbench_names"
        }
    }

    func testApprovalTextMatchesGo() throws {
        let data = try Data(contentsOf: Self.testdata.appendingPathComponent("approval_text_cases.json"))
        let cases = try JSONDecoder().decode([TextCase].self, from: data)
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        for item in cases {
            let action = AgentAction(row: Row([
                "id": 1, "tool": item.tool, "args_json": item.args, "result_json": item.result, "status": "pending"
            ]))
            let text = Self.cardText(action) { item.workbenchNames[String($0)] }
            XCTAssertEqual(text.title, item.expect.title, "\(item.name): title")
            XCTAssertEqual(text.summary, item.expect.summary, "\(item.name): summary")
            XCTAssertEqual(text.editOnMac, item.expect.editOnMac, "\(item.name): edit on Mac")
        }
    }

    /// A pending proposal's card as the Inbox reading pane draws it: a
    /// save_automation as `SaveAutomationProposalPane` (its name, then For /
    /// When / It may, Open Draft), else `AgentActionCardView` (its title;
    /// a connector call's connector, tool and input with Edit Input; a Slack
    /// send's recipient and text with its editor; any other tool's summary
    /// lines).
    private static func cardText(
        _ action: AgentAction, workbenchName: @escaping (Int64) -> String?
    ) -> (title: String, summary: [String], editOnMac: Bool) {
        if action.tool == SaveAutomationCardModel.tool {
            let summary = SaveAutomationProposalSummary(model: SaveAutomationCardModel(action: action),
                                                        workbenchName: workbenchName)
            return (summary.name, ["For: \(summary.scope)", "When: \(summary.when)", "It may: \(summary.mayLine)"], true)
        }
        let title = AgentActionCardView.title(for: action)
        if let connector = ConnectorCallProposal(action: action) {
            return (title, ["Connector: \(connector.server)", "Tool: \(connector.toolName)", connector.inputJSON], true)
        }
        if SlackSendProposal(action: action) != nil, let lines = AgentActionCardView.slackSummaryLines(for: action) {
            return (title, lines, true)
        }
        return (title, AgentActionCardView.summaryLines(for: action), false)
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
            let proposal = item.proposal.map { proposal in
                InboxTargetButtonFacts.Proposal(AgentAction(row: Row([
                    "id": 1, "tool": "create_target", "args_json": "{}", "status": proposal.status,
                    "decided_at": proposal.decidedAt, "dismissed_at": proposal.dismissedAt, "error": proposal.error
                ])))
            }
            let facts = InboxTargetButtonFacts(proposal: proposal, taskID: item.taskExists ? 1 : nil)
            let (detail, note) = Self.wire(TargetButtonStateResolver.state(facts, now: now))
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
