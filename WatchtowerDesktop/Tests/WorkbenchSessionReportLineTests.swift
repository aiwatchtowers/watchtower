import XCTest
import GRDB
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

private struct ScriptedFailure: LocalizedError {
    let errorDescription: String?
}

/// The sessions panel row's report line (spec
/// 2026-10-03-workbench-session-report Part 7): the state label, then
/// "#314 · 14/15 · PR #147 open" from `SessionReportCenter`'s summary.
@MainActor
final class WorkbenchSessionReportLineTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var centers: [SessionReportCenter] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchSessionReportLineTests-\(UUID().uuidString)"))
        centers = []
    }

    override func tearDown() {
        centers.forEach { $0.stop() }
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private static let summary = SessionReportSummary(
        sessionID: 7, targetID: 314, done: 14, total: 15, prLine: "PR #147 open"
    )

    private func session(projectID: Int64?, kind: TerminalSession.Kind = .claude) async throws -> TerminalSession {
        try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(projectID: projectID, kind: kind, title: "Release",
                                                        folderPath: "/tmp/acme", claudeSessionID: UUID().uuidString))
        }
    }

    private func workbench() async throws -> Int64 {
        try await pool.write { try TestDatabase.insertWorkbench($0) }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The line

    func testTheLineIsTheSummaryCaption() {
        let snapshot = WorkbenchesViewModel.SummarySnapshot(value: [7: Self.summary])
        XCTAssertEqual(WorkbenchesViewModel.reportLine(snapshot, sessionID: 7), "#314 · 14/15 · PR #147 open")
    }

    func testAStaleSummaryKeepsTheLastCaptionMarkedStale() {
        let snapshot = WorkbenchesViewModel.SummarySnapshot(value: [7: Self.summary], error: "watchtower exited")
        XCTAssertEqual(WorkbenchesViewModel.reportLine(snapshot, sessionID: 7), "#314 · 14/15 · PR #147 open · stale")
    }

    func testNoLineWithoutASummaryForTheSession() {
        XCTAssertNil(WorkbenchesViewModel.reportLine(nil, sessionID: 7), "no run yet")
        XCTAssertNil(WorkbenchesViewModel.reportLine(.init(value: nil, error: "boom"), sessionID: 7),
                     "the first run failed: no caption to keep")
        XCTAssertNil(WorkbenchesViewModel.reportLine(.init(value: [7: Self.summary]), sessionID: 8),
                     "a session the summary does not list (a shell)")
        XCTAssertNil(WorkbenchesViewModel.reportLine(.init(value: [7: SessionReportSummary(sessionID: 7)]), sessionID: 7),
                     "nothing to say is no line, not an empty one")
    }

    /// The VM reads the center AppState wires, keyed by the row's own
    /// workbench; a failed rerun turns the line stale, never blank.
    func testTheViewModelReadsTheCentersSummary() async throws {
        let runner = FakeCLIRunner(stdout: Data(
            #"[{"session_id": 7, "target_id": 314, "done": 14, "total": 15, "pr_line": "PR #147 open"}]"#.utf8
        ))
        let center = SessionReportCenter(runner: runner)
        centers.append(center)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        vm.sessionReports = center
        XCTAssertNil(vm.reportLine(sessionID: 7, projectID: 3))

        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.value != nil }
        XCTAssertEqual(vm.reportLine(sessionID: 7, projectID: 3), "#314 · 14/15 · PR #147 open")
        XCTAssertNil(vm.reportLine(sessionID: 7, projectID: 4), "another workbench's summary")

        runner.shouldThrow = ScriptedFailure(errorDescription: "watchtower exited with error: busy")
        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.isStale == true }
        XCTAssertEqual(vm.reportLine(sessionID: 7, projectID: 3), "#314 · 14/15 · PR #147 open · stale")
    }

    /// The mini progress bar: done / total of the session's summary; none
    /// without a line or with nothing in scope; a stale summary keeps the
    /// last value.
    func testTheProgressBarValueComesFromTheSummary() async throws {
        XCTAssertEqual(try XCTUnwrap(WorkbenchesViewModel.reportProgress(.init(value: [7: Self.summary]), sessionID: 7)),
                       14.0 / 15.0, accuracy: 0.0001)
        XCTAssertNil(WorkbenchesViewModel.reportProgress(nil, sessionID: 7), "no run yet")
        XCTAssertNil(WorkbenchesViewModel.reportProgress(.init(value: [7: Self.summary]), sessionID: 8), "unlisted")
        XCTAssertNil(WorkbenchesViewModel.reportProgress(.init(value: [7: SessionReportSummary(sessionID: 7, targetID: 3)]),
                                                         sessionID: 7), "nothing in scope")

        let runner = FakeCLIRunner(stdout: Data(
            #"[{"session_id": 7, "target_id": 314, "done": 3, "total": 4, "pr_line": ""}]"#.utf8
        ))
        let center = SessionReportCenter(runner: runner)
        centers.append(center)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
        vm.sessionReports = center
        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.value != nil }
        XCTAssertEqual(vm.reportProgress(sessionID: 7, projectID: 3), 0.75)
        runner.shouldThrow = ScriptedFailure(errorDescription: "watchtower exited with error: busy")
        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.isStale == true }
        XCTAssertEqual(vm.reportProgress(sessionID: 7, projectID: 3), 0.75, "stale: the last value")
    }

    func testAppStateWiresTheCenterIntoTheViewModel() throws {
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: FakeCLIRunner(), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        defer {
            appState.sessionReportCenter?.stop()
            appState.sessionAgentStateCenter?.stop()
            appState.workbenchNotificationCenter?.stop()
            appState.workbenchesViewModel?.asks.stop()
        }
        let center = try XCTUnwrap(appState.sessionReportCenter)
        XCTAssertTrue(appState.workbenchesViewModel?.sessionReports === center)
    }

    // MARK: - The row

    func testTheRowShowsTheStateLabelThenTheReportLine() async throws {
        let row = try await session(projectID: workbench())
        let presented = SessionSwitcherPresentation.rows([row], liveIDs: [], statuses: [:], now: Date())[0]
        let actions = SessionRowActions(open: { _ in }, rename: { _ in }, delete: { _ in })
        let view = TerminalSessionRow(row: presented, actions: actions, reportLine: "#314 · 14/15 · PR #147 open")

        XCTAssertNoThrow(try view.inspect().find(SessionStateLabel.self))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        let labelIndex = try XCTUnwrap(texts.firstIndex { $0.hasPrefix("Not running") })
        let lineIndex = try XCTUnwrap(texts.firstIndex(of: "#314 · 14/15 · PR #147 open"))
        XCTAssertLessThan(labelIndex, lineIndex, "the state label first, then the report line")
        XCTAssertThrowsError(try view.inspect().find(ViewType.ProgressView.self), "no bar without a value")
    }

    func testTheRowDrawsTheMiniProgressBarBesideTheLine() async throws {
        let row = try await session(projectID: workbench())
        let presented = SessionSwitcherPresentation.rows([row], liveIDs: [], statuses: [:], now: Date())[0]
        let view = TerminalSessionRow(row: presented, actions: .init(open: { _ in }, rename: { _ in }, delete: { _ in }),
                                      reportLine: "#314 · 14/15 · PR #147 open", reportProgress: 0.5)
        XCTAssertEqual(try view.inspect().find(ViewType.ProgressView.self).fractionCompleted(), 0.5)
    }

    func testARowWithoutALineShowsOnlyTheLabel() async throws {
        let row = try await session(projectID: workbench())
        let presented = SessionSwitcherPresentation.rows([row], liveIDs: [], statuses: [:], now: Date())[0]
        let view = TerminalSessionRow(row: presented, actions: .init(open: { _ in }, rename: { _ in }, delete: { _ in }))
        XCTAssertNoThrow(try view.inspect().find(SessionStateLabel.self))
        XCTAssertThrowsError(try view.inspect().find(text: "#314 · 14/15 · PR #147 open"))
    }

    func testAStandaloneTerminalShowsNeitherTheLabelNorTheLine() async throws {
        let row = try await session(projectID: nil)
        let presented = SessionSwitcherPresentation.rows([row], liveIDs: [], statuses: [:], now: Date())[0]
        let view = TerminalSessionRow(row: presented, actions: .init(open: { _ in }, rename: { _ in }, delete: { _ in }),
                                      reportLine: "#314 · 14/15 · PR #147 open", reportProgress: 0.5)
        XCTAssertThrowsError(try view.inspect().find(SessionStateLabel.self))
        XCTAssertThrowsError(try view.inspect().find(ViewType.ProgressView.self), "no bar either")
        XCTAssertThrowsError(try view.inspect().find(text: "#314 · 14/15 · PR #147 open"))
    }
}
