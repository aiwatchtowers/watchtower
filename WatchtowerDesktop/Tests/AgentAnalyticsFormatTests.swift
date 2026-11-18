import SwiftUI
import ViewInspector
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Statistics stack's pure helpers (board #1120, Plan 2, Task 7).
final class AgentAnalyticsFormatTests: XCTestCase {
    private static func overview(agentFilter: [String]?) throws -> AgentReportOverview {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/agent-report-overview.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["agent_filter"] = agentFilter
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// D57, ask #1144: the picker's tooltip (no shot shows a tooltip).
    @MainActor
    func testAgentHelp() throws {
        XCTAssertEqual(AgentAnalyticsFormat.agentHelp,
                       "Codex sessions count when they were started from a Watchtower workbench terminal")
        // The segments follow the agent kind registry: All, then each kind's product name.
        XCTAssertEqual(AgentAnalyticsCenter.Agent.allCases.map(AgentAnalyticsFormat.agentTitle),
                       ["All"] + AgentKind.allCases.map(\.displayName))
        XCTAssertEqual(AgentAnalyticsCenter.Agent.allCases.map(\.flag), [nil] + AgentKind.allCases.map(\.rawValue))

        let actions = AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in }, openFile: { _ in },
                                            openAsks: {}, tune: {}, asksWaiting: false)
        let view = AgentAnalyticsOverviewView(
            state: .overview(try Self.overview(agentFilter: ["claude", "codex"]), staleError: nil),
            period: .constant(.week), agent: .constant(.all), actions: actions
        )
        // ViewInspector matches a generic view by its name only: take the
        // first segmented picker (the agent one comes before the period one)
        // and check it is the agent picker by its segments.
        let picker = try view.inspect().find(KitSegmentedPicker<AgentAnalyticsCenter.Agent>.self)
        XCTAssertEqual(try picker.help().string(), AgentAnalyticsFormat.agentHelp)
        XCTAssertNoThrow(try picker.find(text: "Claude Code"))
        XCTAssertThrowsError(try picker.find(text: "7 days"))
    }

    func testPickerShownOnlyWithBothAgents() throws {
        let both = try Self.overview(agentFilter: ["claude", "codex"])
        let one = try Self.overview(agentFilter: nil)
        XCTAssertTrue(AgentAnalyticsFormat.showsAgentPicker(both, filter: .all))
        XCTAssertFalse(AgentAnalyticsFormat.showsAgentPicker(one, filter: .all))
        XCTAssertTrue(AgentAnalyticsFormat.showsAgentPicker(one, filter: .kind(.codex)), "a chosen filter keeps its picker")
    }

    func testShareUnderOnePercent() {
        XCTAssertEqual(AgentAnalyticsFormat.share(1, of: 1000), "<1%")
        XCTAssertEqual(AgentAnalyticsFormat.share(0, of: 10), "0%")
        XCTAssertEqual(AgentAnalyticsFormat.share(46, of: 100), "46%")
        XCTAssertEqual(AgentAnalyticsFormat.share(1, of: 100), "1%")
        XCTAssertEqual(AgentAnalyticsFormat.share(5, of: 0), "0%")
        XCTAssertEqual(AgentAnalyticsFormat.share(0.004), "<1%")
        XCTAssertEqual(AgentAnalyticsFormat.share(0.0), "0%")
    }

    func testToolNameWatchtower() {
        XCTAssertEqual(AgentAnalyticsFormat.toolName("mcp__watchtower-workbench__get_ask"), "Watchtower: get_ask")
        XCTAssertEqual(AgentAnalyticsFormat.toolName("mcp__watchtower__x"), "Watchtower: x")
    }

    func testToolNameOtherServer() {
        XCTAssertEqual(AgentAnalyticsFormat.toolName("mcp__github__get_issue"), "github: get_issue")
        XCTAssertEqual(AgentAnalyticsFormat.toolName("mcp__srv__a__b"), "srv: a__b")
    }

    func testToolNamePlain() {
        XCTAssertEqual(AgentAnalyticsFormat.toolName("Bash"), "Bash")
        XCTAssertEqual(AgentAnalyticsFormat.toolName("mcp__broken"), "mcp__broken")
        XCTAssertEqual(AgentAnalyticsFormat.toolName("mcp____x"), "mcp____x")
    }

    func testGrowthFoldsAfterSix() {
        let split = AgentAnalyticsFormat.fold(Array(1...10), keep: 6)
        XCTAssertEqual(split.shown, Array(1...6))
        XCTAssertEqual(split.rest, Array(7...10))
        XCTAssertTrue(AgentAnalyticsFormat.fold([1, 2], keep: 6).rest.isEmpty)
    }

    func testPartColourStableAcrossOrder() {
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "tools"), .blue)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "instructions"), .purple)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "skills"), .cyan)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "system"), .green)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "hooks"), .orange)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "deferred_tools"), .mint)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "agents"), .indigo)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "mcp"), .teal)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "brand_new"), .gray)
        XCTAssertEqual(AgentAnalyticsPalette.color(forPart: "other"), .gray)
    }
}
