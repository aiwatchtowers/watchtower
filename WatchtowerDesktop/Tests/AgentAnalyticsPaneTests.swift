import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

/// Codex sessions in the Analytics pane (U4, board #975, decision D): the
/// session rows carry their agent's tag and "no price"; the Context and
/// Skills blocks, which a rollout cannot fill, say so in one caption.
@MainActor
final class AgentAnalyticsPaneTests: XCTestCase {
    private func overviewView(_ overview: AgentReportOverview) -> AgentAnalyticsOverviewView {
        AgentAnalyticsOverviewView(
            state: .overview(overview, staleError: nil), period: .constant(.week),
            actions: AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in }, openFile: { _ in },
                                           openAsks: {}, discuss: { _ in }, asksWaiting: false)
        )
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func sessionRows(_ sessions: [AgentSessionRow], compact: Bool = false) -> AgentAnalyticsSessionRows {
        AgentAnalyticsSessionRows(
            sessions: sessions,
            actions: AgentAnalyticsActions(turnOn: {}, openSession: { _ in }, openTarget: { _ in }, openFile: { _ in },
                                           openAsks: {}, discuss: { _ in }, asksWaiting: false),
            compact: compact
        )
    }

    func testCodexRowTagAndNoPrice() throws {
        let overview = try CodexAnalyticsShotFixtures.overview()
        let codex = overview.sessions.filter { $0.agent == "codex" }
        XCTAssertEqual(codex.count, 2)
        let all = try texts(sessionRows(overview.sessions))

        // Each row's tag names its agent by AgentKind's display name.
        XCTAssertEqual(all.filter { $0 == "Codex" }.count, 2, "\(all)")
        XCTAssertEqual(all.filter { $0 == "Claude Code" }.count, overview.sessions.count - 2, "\(all)")
        // A codex session has no price: "no price", never "$0.00".
        XCTAssertEqual(all.filter { $0 == "no price" }.count, 2, "\(all)")
        XCTAssertFalse(all.contains("$0.00"), "\(all)")
        // A priced session that also had an unpriced call keeps its cost.
        XCTAssertTrue(all.contains("$15.00"), "\(all)")

        for session in codex {
            XCTAssertTrue(AgentAnalyticsFormat.hasNoPrice(session))
            XCTAssertEqual(AgentAnalyticsFormat.sessionCost(session), "no price", "the detail and report lines")
            XCTAssertEqual(AgentAnalyticsFormat.agentName(session), "Codex")
        }
        // The narrow rows keep the tag and the cost, and drop the branch.
        let narrow = try texts(sessionRows(overview.sessions, compact: true))
        XCTAssertEqual(narrow.filter { $0 == "Codex" }.count, 2, "\(narrow)")
        XCTAssertEqual(narrow.filter { $0 == "no price" }.count, 2, "\(narrow)")
        XCTAssertFalse(narrow.contains("feature/cache-keys"), "\(narrow)")
        XCTAssertTrue(all.contains("feature/cache-keys"), "\(all)")
        let claude = try XCTUnwrap(overview.sessions.first { $0.uuid.hasPrefix("11111111") })
        XCTAssertFalse(AgentAnalyticsFormat.hasNoPrice(claude), "cost 15 with one unpriced call")
        XCTAssertEqual(AgentAnalyticsFormat.sessionCost(claude), "$15.00")
        XCTAssertEqual(AgentAnalyticsFormat.agentName(claude), "Claude Code")

        // The id still opens the session's detail.
        var opened: [String] = []
        let table = AgentAnalyticsSessionRows(
            sessions: codex,
            actions: AgentAnalyticsActions(turnOn: {}, openSession: { opened.append($0) }, openTarget: { _ in },
                                           openFile: { _ in }, openAsks: {}, discuss: { _ in }, asksWaiting: false),
            compact: false
        )
        try table.inspect().find(button: "33333333").tap()
        XCTAssertEqual(opened, ["33333333-aaaa-bbbb-cccc-000000000003"])
    }

    func testUnknownAgentShowsItsRawName() throws {
        let json = #"""
        {"session_uuid":"55555555","agent":"gemini","cost_estimated_calls":0,"started_at":"","ended_at":"",
         "model":"","branch":"","active_ms":0,"cost_usd":0,"avg_parallel":0,"old_format":false,"prs":[]}
        """#
        let row = try JSONDecoder().decode(AgentSessionRow.self, from: Data(json.utf8))
        XCTAssertNil(row.agentKind)
        XCTAssertEqual(AgentAnalyticsFormat.agentName(row), "gemini")
        XCTAssertFalse(AgentAnalyticsFormat.hasNoPrice(row), "no calls at all is $0.00, not no price")
    }

    func testNotMeasuredCaptionForCodexBlocks() throws {
        let caption = AgentAnalyticsCodexShare.notMeasuredLine
        XCTAssertEqual(caption, "Not measured for Codex sessions.")

        // Claude Code and Codex: Context and Skills keep their findings and
        // add the caption; Trouble (which codex fills) has none.
        let mixed = try texts(overviewView(CodexAnalyticsShotFixtures.overview()))
        XCTAssertEqual(mixed.filter { $0 == caption }.count, 2, "\(mixed)")
        XCTAssertTrue(mixed.contains { $0.hasPrefix("At session start") }, "Context still measured")
        XCTAssertTrue(mixed.contains("Never used (2)"), "Skills still measured")

        // Only Codex: the caption stands alone, no "older sessions" line.
        let only = try CodexAnalyticsShotFixtures.overview(codexOnly: true)
        XCTAssertEqual(AgentAnalyticsCodexShare.of(only.sessions), .all)
        let alone = try texts(overviewView(only))
        XCTAssertEqual(alone.filter { $0 == caption }.count, 2, "\(alone)")
        XCTAssertFalse(alone.contains { $0.hasPrefix("At session start") }, "\(alone)")
        XCTAssertFalse(alone.contains(AgentAnalyticsBlockState.notMeasuredLine), "\(alone)")

        // No Codex session: no caption.
        let claudeOnly = try StatisticsShotFixtures.decode()
        XCTAssertEqual(AgentAnalyticsCodexShare.of(claudeOnly.sessions), .none)
        XCTAssertFalse(try texts(overviewView(claudeOnly)).contains(caption))
        XCTAssertEqual(AgentAnalyticsCodexShare.of([]), .none)
    }

    /// The share counts the sessions whose agent's capability row has no
    /// context breakdown (`AgentSessionCaps.analyticsContext`), not a kind.
    func testShareReadsTheAnalyticsContextCapability() throws {
        let mixed = try CodexAnalyticsShotFixtures.overview()
        XCTAssertEqual(AgentAnalyticsCodexShare.of(mixed.sessions), .some)
        let none = AgentSessionCaps(midturnInput: false, phoneInput: false, permissionWait: false, idleSignal: false,
                                    elicitation: false)
        let withoutBreakdown = AgentAnalyticsCodexShare.of(mixed.sessions) { _ in none }
        XCTAssertEqual(withoutBreakdown, .all, "every agent without the breakdown")
        let all = AgentSessionCaps(midturnInput: false, phoneInput: false, permissionWait: false, idleSignal: false,
                                   elicitation: false, analyticsContext: true)
        XCTAssertEqual(AgentAnalyticsCodexShare.of(mixed.sessions) { _ in all }, .none)
    }
}
