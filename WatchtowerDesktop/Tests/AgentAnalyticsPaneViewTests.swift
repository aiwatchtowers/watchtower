import XCTest
import AppKit
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Records what the Analytics pane's links asked for.
@MainActor
private final class AnalyticsActionLog {
    var turnOns = 0
    var sessions: [String] = []
    var targets: [Int64] = []

    var actions: AgentAnalyticsActions {
        AgentAnalyticsActions(
            turnOn: { self.turnOns += 1 },
            openSession: { self.sessions.append($0) },
            openTarget: { self.targets.append($0) }
        )
    }
}

/// The Analytics pane (#298): what each state shows and where its links
/// go. View inspection over the decoded fixtures, plus the view model's
/// navigation and a light/dark render of the category colours.
@MainActor
final class AgentAnalyticsPaneViewTests: XCTestCase {
    private typealias OverviewSnapshot = SessionReportCenter.Snapshot<AgentReportOverview>
    private typealias DetailSnapshot = SessionReportCenter.Snapshot<AgentSessionDetail>

    nonisolated private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/\(name).json")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    private static func overview() throws -> AgentReportOverview {
        try JSONDecoder().decode(AgentReportOverview.self, from: fixture("agent-report-overview"))
    }

    private static func detail() throws -> AgentSessionDetail {
        try JSONDecoder().decode(AgentSessionDetail.self, from: fixture("agent-report-session"))
    }

    /// The fixture with `enabled` flipped off.
    private static func offOverview() throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["enabled"] = false
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The fixture with `import` replaced by `state`/`files`, or removed for nil.
    private static func importOverview(state: String?, files: Int = 0) throws -> AgentReportOverview {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("agent-report-overview")) as? [String: Any])
        json["import"] = state.map { ["state": $0, "files_stored": files, "updated_at": "2026-10-18T17:00:00Z"] }
        return try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func overviewView(
        _ state: AgentAnalyticsPaneState, period: AgentAnalyticsCenter.Period = .week, log: AnalyticsActionLog? = nil
    ) -> AgentAnalyticsOverviewView {
        AgentAnalyticsOverviewView(state: state, period: .constant(period), actions: (log ?? AnalyticsActionLog()).actions)
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: - State

    func testStateFollowsTheSnapshotAndEnabling() throws {
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: nil, enabling: false), .loading)
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(error: "boom"), enabling: false), .failed("boom"))
        let off = try Self.offOverview()
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: off), enabling: false),
                       .off(enabling: false, error: nil))
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: off), enabling: true),
                       .off(enabling: true, error: nil))
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: off, error: "enable failed"), enabling: false),
                       .off(enabling: false, error: "enable failed"))
        let on = try Self.overview()
        XCTAssertEqual(AgentAnalyticsPaneState.make(overview: OverviewSnapshot(value: on, error: "stale"), enabling: false),
                       .overview(on, staleError: "stale"))
    }

    // MARK: - Off

    func testOffShowsTurnOnAndCallsIt() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.off(enabling: false, error: nil), log: log)
        try view.inspect().find(button: "Turn On").tap()
        XCTAssertEqual(log.turnOns, 1)
        XCTAssertThrowsError(try view.inspect().find(ViewType.ProgressView.self))
    }

    func testEnablingShowsProgressWithoutTurnOn() throws {
        let view = overviewView(.off(enabling: true, error: nil))
        XCTAssertNoThrow(try view.inspect().find(ViewType.ProgressView.self))
        XCTAssertThrowsError(try view.inspect().find(button: "Turn On"))
    }

    func testOffShowsTheEnableError() throws {
        let view = overviewView(.off(enabling: false, error: "agents enable failed"))
        XCTAssertNoThrow(try view.inspect().find(text: "agents enable failed"))
        XCTAssertNoThrow(try view.inspect().find(button: "Turn On"))
    }

    // MARK: - Overview

    func testTilesShowActiveCostSessionsAndParallelism() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertTrue(all.contains("50m"), "active 3 030 000 ms: \(all)")
        XCTAssertTrue(all.contains("10m"), "away")
        XCTAssertTrue(all.contains("$15.50"))
        XCTAssertTrue(all.contains("2"), "sessions")
        XCTAssertTrue(all.contains("Subagents: 1.0 at once on average · peak 1"), "\(all)")
        XCTAssertTrue(all.contains("1 call priced by estimate"), "\(all)")
    }

    func testTimeBreakdownLegendAndFootnote() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        // Shares of active time (3 030 000): tools 363 000, model 82 000, background 785 000, you 1 800 000.
        XCTAssertTrue(all.contains("Tools 12%"), "\(all)")
        XCTAssertTrue(all.contains("Model 3%"))
        XCTAssertTrue(all.contains("Background agents 26%"))
        XCTAssertTrue(all.contains("You 59%"))
        XCTAssertTrue(all.contains("build & test 12% · MCP 0% · other 0%"), "\(all)")
        XCTAssertTrue(all.contains("Tool time includes permission prompts."))
    }

    func testHintsKeepTheirOrderAndEachItsOwnEstimate() throws {
        let ov = try Self.overview()
        let all = try texts(overviewView(.overview(ov, staleError: nil)))
        let findings = all.filter { text in ov.hints.contains { $0.finding == text } }
        XCTAssertEqual(findings, ov.hints.map(\.finding))
        XCTAssertTrue(all.contains("4m"), "H1's time estimate")
        XCTAssertTrue(all.contains("$15.00"), "H6's money estimate")
        XCTAssertFalse(all.contains { $0.localizedCaseInsensitiveContains("total") && $0.contains("sav") },
                       "no summed savings")
    }

    func testHintEvidenceLinksOpenTheTargetAndTheSession() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        try view.inspect().find(button: "#1 Add widget").tap()
        try view.inspect().find(button: "Session 11111111").tap()
        XCTAssertEqual(log.targets, [1])
        XCTAssertEqual(log.sessions, ["11111111-aaaa-bbbb-cccc-000000000001"])
    }

    func testOldFormatSessionsAreCounted() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertTrue(all.contains("Older sessions — time not analysed: 1"))
    }

    func testSharedTaskRowSaysSoAndOpensTheTarget() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        let all = try texts(view)
        XCTAssertTrue(all.contains("shared"))
        try view.inspect().find(button: "#2 Fix login").tap()
        XCTAssertEqual(log.targets, [2])
    }

    func testSessionRowOpensItsDetail() throws {
        let log = AnalyticsActionLog()
        let view = overviewView(.overview(try Self.overview(), staleError: nil), log: log)
        try view.inspect().find(button: "11111111").tap()
        XCTAssertEqual(log.sessions, ["11111111-aaaa-bbbb-cccc-000000000001"])
    }

    func testCommandsAndModelsSections() throws {
        let all = try texts(overviewView(.overview(try Self.overview(), staleError: nil)))
        XCTAssertTrue(all.contains("make test"))
        XCTAssertTrue(all.contains("claude-opus-5-5"))
        XCTAssertTrue(all.contains("28%"), "cache read share")
    }

    func testThePeriodLabelComesFromTheReportAndAChangedPickerSaysUpdating() throws {
        let ov = try Self.overview()
        XCTAssertEqual(AgentAnalyticsFormat.period(of: ov), .week)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(AgentAnalyticsFormat.periodLabel(ov, timeZone: utc), "Oct 1 – Oct 8")

        XCTAssertThrowsError(try overviewView(.overview(ov, staleError: nil), period: .week).inspect().find(text: "Updating…"))
        XCTAssertNoThrow(try overviewView(.overview(ov, staleError: nil), period: .month).inspect().find(text: "Updating…"))
    }

    func testAllHistoryPeriod() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.fixture("agent-report-overview")) as? [String: Any])
        json["since"] = ""
        let ov = try JSONDecoder().decode(AgentReportOverview.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(AgentAnalyticsFormat.period(of: ov), .all)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(AgentAnalyticsFormat.periodLabel(ov, timeZone: utc), "All history to Oct 8")
    }

    func testDurations() {
        XCTAssertEqual(AgentAnalyticsFormat.duration(0), "0s")
        XCTAssertEqual(AgentAnalyticsFormat.duration(45000), "45s")
        XCTAssertEqual(AgentAnalyticsFormat.duration(1_650_000), "27m")
        XCTAssertEqual(AgentAnalyticsFormat.duration(51_600_000), "14h 20m")
        XCTAssertEqual(AgentAnalyticsFormat.duration(111_600_000), "31h")
    }

    // MARK: - Session detail

    func testSessionDetailHasOneLanePerSubagentPlusMain() throws {
        let det = try Self.detail()
        let view = AgentSessionAnalyticsView(
            snapshot: DetailSnapshot(value: det), onBack: {}, actions: AnalyticsActionLog().actions)
        let all = try texts(view)
        let lanes = det.lanes.map(AgentSessionTimelineView.laneTitle)
        XCTAssertEqual(lanes, ["Main agent", "general-purpose · background"])
        XCTAssertEqual(all.filter(lanes.contains), lanes)
        XCTAssertTrue(all.contains(det.hints[0].finding))
        XCTAssertTrue(all.contains("Tool time includes permission prompts."))
    }

    func testSessionDetailBackAndLoading() throws {
        var backs = 0
        let loading = AgentSessionAnalyticsView(snapshot: nil, onBack: { backs += 1 }, actions: AnalyticsActionLog().actions)
        XCTAssertNoThrow(try loading.inspect().find(ViewType.ProgressView.self))
        try loading.inspect().find(button: "Back").tap()
        XCTAssertEqual(backs, 1)
        let failed = AgentSessionAnalyticsView(snapshot: DetailSnapshot(error: "no such session"), onBack: {},
                                               actions: AnalyticsActionLog().actions)
        XCTAssertNoThrow(try failed.inspect().find(text: "no such session"))
    }

    func testSegmentDescription() throws {
        let det = try Self.detail()
        XCTAssertEqual(AgentSessionTimelineView.describe(det.lanes[0].segments[5]), "Tools · build & test · make test · 2m")
        XCTAssertEqual(AgentSessionTimelineView.describe(det.lanes[0].segments[0]), "Model · 10s")
    }

    // MARK: - Session report line

    func testReportLineOnlyForAMatchingSession() throws {
        let ov = try Self.overview()
        XCTAssertNil(SessionReportAnalyticsLine.row(in: ov, claudeSessionID: "nope"))
        XCTAssertNil(SessionReportAnalyticsLine.row(in: ov, claudeSessionID: nil))
        XCTAssertNil(SessionReportAnalyticsLine.row(in: nil, claudeSessionID: "11111111-aaaa-bbbb-cccc-000000000001"))
        let row = try XCTUnwrap(SessionReportAnalyticsLine.row(in: ov, claudeSessionID: "11111111-aaaa-bbbb-cccc-000000000001"))
        var opened = 0
        let line = SessionReportAnalyticsLine(row: row) { opened += 1 }
        XCTAssertNoThrow(try line.inspect().find(text: "Agent time 50m · $15.00 ·"))
        try line.inspect().find(button: "Analytics").tap()
        XCTAssertEqual(opened, 1)
    }

    func testShowSessionAnalyticsOpensThePaneOnTheSession() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentAnalyticsPaneViewTests-\(UUID().uuidString)"))
        let projectID = try await pool.write { d in try TestDatabase.insertWorkbench(d, folder: "/tmp/acme") }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: nil)
        vm.showSessionAnalytics("u-1", projectID: projectID)
        XCTAssertEqual(vm.analyticsSession[projectID], "u-1")
        XCTAssertTrue(vm.layout(projectID: projectID).visiblePanes.contains(.analytics))
    }

    /// Opening a session's detail and going back keeps the pane shown: the
    /// center is not hidden and the overview does not run again.
    func testSwitchingToADetailAndBackKeepsTheOverviewShown() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AgentAnalyticsPaneViewTests-\(UUID().uuidString)"))
        let projectID = try await pool.write { d in try TestDatabase.insertWorkbench(d, folder: "/tmp/acme") }
        let project = try await pool.read { d in
            try XCTUnwrap(Workbench.fetchOne(d, sql: "SELECT * FROM projects WHERE id = ?", arguments: [projectID]))
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: nil)
        let runner = FakeCLIRunner(stdout: Self.fixture("agent-report-overview"))
        let center = AgentAnalyticsCenter(runner: runner, interval: .seconds(3600))
        defer { center.stop() }
        vm.agentAnalytics = center

        let host = NSHostingView(rootView: AgentAnalyticsPaneView(vm: vm, project: project))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func settle() async {   // lay the view out, then let the center's runs finish
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try? await Task.sleep(for: .milliseconds(100))
        }
        func overviewRuns() -> Int { runner.invocations.filter { !$0.contains("--session") }.count }
        await settle()
        XCTAssertEqual(overviewRuns(), 1)
        XCTAssertTrue(center.isPolling)

        vm.analyticsSession[projectID] = "11111111-aaaa-bbbb-cccc-000000000001"
        await settle()
        XCTAssertTrue(center.isPolling, "the detail does not hide the pane")
        vm.analyticsSession[projectID] = nil
        await settle()
        XCTAssertEqual(overviewRuns(), 1, "back to the overview reruns nothing")
        XCTAssertTrue(center.isPolling)
        XCTAssertEqual(runner.invocations.filter { $0.contains("--session") }.count, 1)
    }

    // MARK: - History import (#849)

    func testImportLine() throws {
        func line(_ state: String, _ files: Int, _ locale: String = "en_US") throws -> String? {
            let importState = try XCTUnwrap(Self.importOverview(state: state, files: files).importState)
            return AgentAnalyticsFormat.importLine(importState, locale: Locale(identifier: locale))
        }
        XCTAssertNil(try line("done", 1234))
        XCTAssertEqual(try line("loading", 1234), "Loading history — 1,234 files so far")
        XCTAssertEqual(try line("not_started", 0), "Loading history — 0 files so far")
        XCTAssertEqual(try line("loading", 1234, "de_DE"), "Loading history — 1.234 files so far")
        XCTAssertEqual(try line("waiting_for_move", 0),
                       "History not moved yet — restart the daemon or run watchtower agents scan")
    }

    /// Before the move the pane shows a warning, not a loading line that never moves.
    func testOverviewShowsTheMoveWarning() throws {
        let all = try texts(overviewView(.overview(Self.importOverview(state: "waiting_for_move"), staleError: nil)))
        XCTAssertTrue(all.contains("History not moved yet — restart the daemon or run watchtower agents scan"), "\(all)")
        XCTAssertFalse(all.contains { $0.hasPrefix("Loading history") }, "\(all)")
        let state = try XCTUnwrap(Self.importOverview(state: "waiting_for_move").importState)
        XCTAssertTrue(AgentAnalyticsFormat.isImportWarning(state))
        XCTAssertFalse(AgentAnalyticsFormat.isImportWarning(try XCTUnwrap(Self.importOverview(state: "loading").importState)))
    }

    /// The loading line sits above the overview until the import is done;
    /// an older binary that sends no `import` shows none.
    func testOverviewShowsTheLoadingLineUntilDone() throws {
        func lines(_ overview: AgentReportOverview) throws -> [String] {
            try texts(overviewView(.overview(overview, staleError: nil)))
        }
        XCTAssertTrue(try lines(Self.overview()).contains("Loading history — 2 files so far"))   // the Go fixture
        XCTAssertTrue(try lines(Self.importOverview(state: "loading", files: 1234))
            .contains("Loading history — \(1234.formatted()) files so far"))
        XCTAssertTrue(try lines(Self.importOverview(state: "not_started")).contains("Loading history — 0 files so far"))
        for state in ["done", nil] as [String?] {
            let all = try lines(Self.importOverview(state: state, files: 1234))
            XCTAssertFalse(all.contains { $0.hasPrefix("Loading history") }, "\(String(describing: state)): \(all)")
        }
    }

    // MARK: - Colours

    /// "You" has its own colour, not the orange of the pane's error lines,
    /// and no two categories share one.
    func testOwnerColourIsNotTheErrorOrange() {
        XCTAssertNotEqual(AgentTimeCategory.owner.color, .orange)
        let colours = [AgentTimeCategory.model, .tool, .background, .owner, .away].map(\.color)
        XCTAssertEqual(Set(colours.map(\.description)).count, colours.count)
    }

    /// The time bar draws its colours in both appearances (not the window's
    /// background, not transparent).
    func testTimeBarRendersInLightAndDark() throws {
        let probe = ViewRenderProbe(size: NSSize(width: 200, height: 20))
        let bar = AgentAnalyticsTimeBar(time: try Self.overview().time)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let bitmap = try probe.render(bar, appearance)
            let pixel = try probe.pixel(bitmap, x: 10, y: 10)
            XCTAssertEqual(pixel.alpha, 255, "\(name.rawValue): \(pixel)")
            let background = appearance.name == .darkAqua ? 30 : 236
            XCTAssertFalse(pixel.red == pixel.green && pixel.green == pixel.blue && abs(pixel.red - background) < 20,
                           "\(name.rawValue): \(pixel) looks like the background")
        }
    }
}
