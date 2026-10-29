import SwiftUI
import XCTest
@testable import WatchtowerDesktop

/// The Statistics stack's pure helpers (board #1120, Plan 2, Task 7).
final class AgentAnalyticsFormatTests: XCTestCase {
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
