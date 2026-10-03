import XCTest
import AppKit
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `workbench session-report` calls from a script, optionally holding
/// each call open until the test releases it. No process is spawned.
private final class ScriptedReportRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var gates: [AsyncGate] = []
    private var holding = false
    private var answer: @Sendable ([String]) throws -> Data

    init(_ answer: @escaping @Sendable ([String]) throws -> Data) {
        self.answer = answer
    }

    /// Every `session-report` call so far (other CLI calls the AppState
    /// wiring makes are not recorded).
    var invocations: [[String]] { lock.withLock { calls } }

    /// From now on, each call waits for `release(_:)`.
    func hold() { lock.withLock { holding = true } }

    func answer(_ next: @escaping @Sendable ([String]) throws -> Data) {
        lock.withLock { answer = next }
    }

    /// Lets the `index`-th call return.
    func release(_ index: Int) {
        lock.withLock { gates[index] }.release()
    }

    func run(args: [String]) async throws -> Data {
        guard args.starts(with: ["workbench", "session-report"]) else { return Data("{}".utf8) }
        let gate = AsyncGate()
        let held = lock.withLock {
            calls.append(args)
            gates.append(gate)
            return holding
        }
        if held { await gate.wait() }
        return try lock.withLock { answer }(args)
    }
}

/// A stand-in for `SessionAgentStateCenter.statuses`, observable the same way.
@MainActor
@Observable
private final class FakeAgentStates {
    var states: [Int64: SessionSwitcherPresentation.State] = [:]
}

private struct ScriptedFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
final class SessionReportCenterTests: XCTestCase {
    private var centers: [SessionReportCenter] = []
    private var activations: NotificationCenter!

    override func setUp() {
        super.setUp()
        centers = []
        activations = NotificationCenter()
    }

    override func tearDown() {
        // No loop or run outlives its test.
        centers.forEach { $0.stop() }
        super.tearDown()
    }

    private func makeCenter(
        _ runner: ScriptedReportRunner,
        summaryInterval: Duration = .seconds(3600),
        reportInterval: Duration = .seconds(3600)
    ) -> SessionReportCenter {
        let center = SessionReportCenter(
            runner: runner, summaryInterval: summaryInterval, reportInterval: reportInterval,
            notificationCenter: activations
        )
        centers.append(center)
        return center
    }

    nonisolated private static func summaryJSON(_ session: Int64, done: Int) -> Data {
        Data(#"[{"session_id": \#(session), "target_id": 314, "done": \#(done), "total": 15, "pr_line": "PR #147 open"}]"#.utf8)
    }

    nonisolated private static func reportJSON(_ session: Int64, done: Int = 1) -> Data {
        Data(#"{"session": {"id": \#(session), "title": "Release"}, "progress": {"done": \#(done), "total": 4}}"#.utf8)
    }

    /// Answers by the call's own flags: a summary for `--summary`, a report
    /// of the asked session for `--session`.
    nonisolated private static func byFlags(done: Int = 1) -> @Sendable ([String]) throws -> Data {
        { args in
            if let i = args.firstIndex(of: "--session"), let id = Int64(args[i + 1]) {
                return reportJSON(id, done: done)
            }
            return summaryJSON(7, done: done)
        }
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

    /// Lets queued main-actor work (a finished run, a queued rerun) settle.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    // MARK: - Summary

    func testSummaryPollRunsOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        var onScreen = false
        center.isTabOnScreen = { onScreen }
        center.watchedWorkbenchID = { 3 }

        center.pollSummaries()
        await settle()
        XCTAssertEqual(runner.invocations, [], "no run while the tab is not on screen")

        onScreen = true
        center.pollSummaries()
        await waitUntil { center.summaries[3]?.value != nil }
        XCTAssertEqual(runner.invocations, [
            ["workbench", "session-report", "--workbench", "3", "--summary", "--json"]
        ])
        XCTAssertEqual(center.summaries[3]?.value?[7], .init(sessionID: 7, targetID: 314, done: 1, total: 15, prLine: "PR #147 open"))
        XCTAssertEqual(center.summaries[3]?.isStale, false)
    }

    func testSummaryPollNeedsAWorkbenchOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.isTabOnScreen = { true }
        center.watchedWorkbenchID = { nil }

        center.pollSummaries()
        await settle()
        XCTAssertEqual(runner.invocations, [])
    }

    func testSummaryLoopTicksAtItsIntervalWhileTheTabIsOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner, summaryInterval: .milliseconds(20))
        var onScreen = false
        center.isTabOnScreen = { onScreen }
        center.watchedWorkbenchID = { 3 }
        XCTAssertEqual(SessionReportCenter.summaryInterval, .seconds(15))

        center.start()
        XCTAssertTrue(center.isPollingSummaries)
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(runner.invocations, [], "ticks while the tab is hidden run nothing")

        onScreen = true
        await waitUntil { runner.invocations.count >= 2 }

        center.stop()
        XCTAssertFalse(center.isPollingSummaries)
        await settle()
        let count = runner.invocations.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(runner.invocations.count, count, "no tick after stop")
    }

    func testActivationRefreshesTheWatchedWorkbench() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.watchedWorkbenchID = { 5 }
        center.start()

        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { center.summaries[5]?.value != nil }
        XCTAssertEqual(runner.invocations.map { $0[3] }, ["5"])
    }

    // MARK: - Full report

    func testShowRunsTheReportAndItsLoopRunsWhileShown() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner, reportInterval: .milliseconds(20))
        center.isTabOnScreen = { true }
        XCTAssertEqual(SessionReportCenter.reportInterval, .seconds(30))

        center.show(session: 9, workbench: 3)
        XCTAssertEqual(center.shown, .init(session: 9, workbench: 3))
        XCTAssertTrue(center.isPollingReport)
        await waitUntil { center.reports[9]?.value != nil }
        XCTAssertEqual(runner.invocations.first, [
            "workbench", "session-report", "--workbench", "3", "--session", "9", "--json"
        ])
        XCTAssertEqual(center.reports[9]?.value?.session.id, 9)
        await waitUntil { runner.invocations.count >= 3 }

        center.hide(session: 9)
        XCTAssertNil(center.shown)
        XCTAssertFalse(center.isPollingReport)
        await settle()
        let count = runner.invocations.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(runner.invocations.count, count, "no run once hidden")
        XCTAssertNotNil(center.reports[9]?.value, "the last report stays for the next show")
    }

    func testReportTicksRunOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner, reportInterval: .milliseconds(20))
        var onScreen = false
        center.isTabOnScreen = { onScreen }

        center.show(session: 9, workbench: 3)
        await waitUntil { center.reports[9]?.value != nil }
        XCTAssertEqual(runner.invocations.count, 1, "show runs whatever the tab")
        try? await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(runner.invocations.count, 1, "ticks while the tab is hidden run nothing")
        XCTAssertTrue(center.isPollingReport, "the loop keeps ticking, gated")

        onScreen = true
        await waitUntil { runner.invocations.count >= 3 }

        onScreen = false
        await settle()
        let count = runner.invocations.count
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(runner.invocations.count, count, "hidden again: the ticks stop running")
    }

    func testAnAgentStateChangeRerunsWhileTheTabIsHidden() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        let agents = FakeAgentStates()
        agents.states[9] = .live(.working)
        center.agentState = { agents.states[$0] }
        center.isTabOnScreen = { false }

        center.show(session: 9, workbench: 3)
        await waitUntil { runner.invocations.count == 1 }
        agents.states[9] = .live(.stopped)
        await waitUntil { runner.invocations.count == 2 }
    }

    private func reportRuns(_ runner: ScriptedReportRunner) -> Int {
        runner.invocations.filter { $0.contains("--session") }.count
    }

    /// The tab back on screen — the app comes forward, a window is
    /// uncovered — refreshes the shown report at once, not at the next tick.
    func testTheShownReportRefreshesAtOnceWhenTheTabComesBack() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        var onScreen = true
        center.isTabOnScreen = { onScreen }
        center.start()
        center.show(session: 9, workbench: 3)
        await waitUntil { self.reportRuns(runner) == 1 }

        onScreen = false
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await settle()
        XCTAssertEqual(reportRuns(runner), 1, "going off screen runs nothing")
        onScreen = true
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { self.reportRuns(runner) == 2 }

        onScreen = false
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await settle()
        onScreen = true
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await waitUntil { self.reportRuns(runner) == 3 }
        XCTAssertEqual(runner.invocations.last, [
            "workbench", "session-report", "--workbench", "3", "--session", "9", "--json"
        ])
    }

    /// Activation or a window change while the report stays on screen runs
    /// nothing extra; with no Session view shown, nothing either.
    func testAScreenChangeWithTheReportStillOnScreenRunsNothing() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.isTabOnScreen = { true }
        center.start()
        center.show(session: 9, workbench: 3)
        await waitUntil { self.reportRuns(runner) == 1 }

        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await settle()
        XCTAssertEqual(reportRuns(runner), 1)

        center.hide(session: 9)
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await settle()
        XCTAssertEqual(reportRuns(runner), 1, "no Session view shown")
    }

    /// Coming back while a run is in flight queues one rerun, however often.
    func testComingBackKeepsOneRunInFlightPlusOneQueued() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)
        var onScreen = true
        center.isTabOnScreen = { onScreen }
        center.show(session: 9, workbench: 3)
        await waitUntil { self.reportRuns(runner) == 1 }

        for _ in 0..<3 {
            onScreen = false
            center.screenMayHaveChanged()
            onScreen = true
            center.screenMayHaveChanged()
        }
        await settle()
        XCTAssertEqual(reportRuns(runner), 1, "the run in flight is not doubled")
        runner.release(0)
        await waitUntil { self.reportRuns(runner) == 2 }
        // No queued rerun means no second call to release.
        guard reportRuns(runner) == 2 else { return }
        runner.release(1)
        await settle()
        XCTAssertEqual(reportRuns(runner), 2, "one queued rerun, not three")
    }

    func testShowingTheSameSessionAgainStartsNoSecondRun() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await waitUntil { center.reports[9]?.value != nil }
        center.show(session: 9, workbench: 3)
        await settle()
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testHidingAnotherSessionKeepsTheShownOne() {
        let center = makeCenter(ScriptedReportRunner(Self.byFlags()))
        center.show(session: 9, workbench: 3)
        center.hide(session: 4)
        XCTAssertEqual(center.shown, .init(session: 9, workbench: 3))
        XCTAssertTrue(center.isPollingReport)
    }

    func testAnAgentStateChangeRerunsTheShownReport() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        let agents = FakeAgentStates()
        agents.states[9] = .live(.working)
        center.agentState = { agents.states[$0] }

        center.show(session: 9, workbench: 3)
        await waitUntil { runner.invocations.count == 1 && center.reports[9]?.value != nil }

        agents.states[4] = .live(.stopped)
        await settle()
        XCTAssertEqual(runner.invocations.count, 1, "another session's change reruns nothing")

        agents.states[9] = .live(.needsApproval)
        await waitUntil { runner.invocations.count == 2 }
        await settle()
        XCTAssertEqual(runner.invocations.count, 2, "one rerun per change")

        agents.states[9] = .live(.stopped)
        await waitUntil { runner.invocations.count == 3 }

        center.hide(session: 9)
        agents.states[9] = .live(.working)
        await settle()
        XCTAssertEqual(runner.invocations.count, 3, "a hidden session's change reruns nothing")
    }

    // MARK: - Concurrency

    func testOneRunInFlightPlusOneQueuedRerunPerWorkbench() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.refresh(workbench: 3)
        await waitUntil { runner.invocations.count == 1 }
        center.refresh(workbench: 3)
        center.refresh(workbench: 3)
        center.refresh(workbench: 3)
        center.refresh(workbench: 4)
        await waitUntil { runner.invocations.count == 2 }
        await settle()
        XCTAssertEqual(runner.invocations.map { $0[3] }, ["3", "4"], "another workbench runs in parallel; the reruns wait")

        runner.release(0)
        await waitUntil { runner.invocations.count == 3 }
        XCTAssertEqual(runner.invocations[2][3], "3", "exactly one queued rerun")
        runner.release(2)
        runner.release(1)
        await settle()
        XCTAssertEqual(runner.invocations.count, 3, "the queue held one rerun, not three")
    }

    func testTheReportRunAndTheSummaryRunDoNotQueueBehindEachOther() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        center.refresh(workbench: 3)
        await waitUntil { runner.invocations.count == 2 }
        runner.release(0)
        runner.release(1)
    }

    // MARK: - Failures

    func testAFailedSummaryKeepsTheLastValueMarkedStale() async {
        let runner = ScriptedReportRunner(Self.byFlags(done: 14))
        let center = makeCenter(runner)

        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.value != nil }

        runner.answer { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "unknown workbench 3\nmore detail") }
        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.isStale == true }
        XCTAssertEqual(center.summaries[3]?.value?[7]?.done, 14, "the last good rows stay")
        XCTAssertEqual(center.summaries[3]?.error, "watchtower exited with error: unknown workbench 3")
        if let summary = center.summaries[3]?.value?[7] {
            XCTAssertEqual(SessionReportPresentation.rowCaption(summary, stale: true), "#314 · 14/15 · PR #147 open · stale")
        }

        runner.answer(Self.byFlags(done: 15))
        center.refresh(workbench: 3)
        await waitUntil { center.summaries[3]?.isStale == false }
        XCTAssertEqual(center.summaries[3]?.value?[7]?.done, 15)
        XCTAssertNil(center.summaries[3]?.error)
    }

    func testAFailedReportKeepsTheLastReportMarkedStale() async {
        let runner = ScriptedReportRunner(Self.byFlags(done: 2))
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await waitUntil { center.reports[9]?.value != nil }

        runner.answer { _ in Data("not json".utf8) }
        center.refreshShownReport()
        await waitUntil { center.reports[9]?.isStale == true }
        XCTAssertEqual(center.reports[9]?.value?.progress.done, 2, "the last good report stays")
        XCTAssertNotNil(center.reports[9]?.error)
    }

    func testAFirstRunFailureHasNoValueButAnErrorLine() async {
        let runner = ScriptedReportRunner { _ in throw ScriptedFailure(errorDescription: "watchtower binary not found.") }
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await waitUntil { center.reports[9]?.error != nil }
        XCTAssertNil(center.reports[9]?.value)
        XCTAssertEqual(center.reports[9]?.error, "watchtower binary not found.")
    }

    // MARK: - Session switch

    func testASessionSwitchCancelsNothingAndDropsTheOldSessionsResult() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await waitUntil { runner.invocations.count == 1 }
        center.show(session: 10, workbench: 3)
        await settle()
        XCTAssertEqual(runner.invocations.count, 1, "the old run is not cancelled; the new one waits behind it")

        runner.release(0)
        await waitUntil { runner.invocations.count == 2 }
        XCTAssertNil(center.reports[9], "the old session's late result is dropped")
        XCTAssertEqual(runner.invocations[1][5], "10", "the queued rerun is for the session now shown")

        runner.release(1)
        await waitUntil { center.reports[10]?.value != nil }
        XCTAssertEqual(center.reports[10]?.value?.session.id, 10)
        XCTAssertNil(center.reports[9])
    }

    func testAFailureOfTheOldSessionIsDroppedToo() async {
        let runner = ScriptedReportRunner { _ in throw ScriptedFailure(errorDescription: "boom") }
        runner.hold()
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await waitUntil { runner.invocations.count == 1 }
        center.hide(session: 9)
        runner.release(0)
        await settle()
        XCTAssertNil(center.reports[9])
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testStopCancelsTheRunsInFlight() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.refresh(workbench: 3)
        await waitUntil { runner.invocations.count == 1 }
        center.refresh(workbench: 3)
        center.stop()
        runner.release(0)
        await settle()
        XCTAssertNil(center.summaries[3], "a cancelled run's result is not applied")
        XCTAssertEqual(runner.invocations.count, 1, "the queued rerun is dropped")

        // The center works again after a stop.
        center.refresh(workbench: 3)
        await waitUntil { runner.invocations.count == 2 }
        runner.release(1)
        await waitUntil { center.summaries[3]?.value != nil }
    }

    // MARK: - AppState

    func testTheCenterLivesOnAppStateAndSurvivesNavigation() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let runner = ScriptedReportRunner(Self.byFlags())
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        defer {
            appState.sessionReportCenter?.stop()
            appState.sessionAgentStateCenter?.stop()
            appState.workbenchNotificationCenter?.stop()
            appState.workbenchesViewModel?.asks.stop()
        }
        let center = try XCTUnwrap(appState.sessionReportCenter)
        XCTAssertTrue(center.isPollingSummaries, "started with the Workbench wiring")

        appState.selectedDestination = .workbench
        center.show(session: 9, workbench: 3)
        await waitUntil { center.reports[9]?.value != nil }

        appState.selectedDestination = .inbox
        appState.selectedDestination = .workbench

        XCTAssertTrue(appState.sessionReportCenter === center, "the same AppState-owned center, not a fresh one")
        XCTAssertEqual(center.shown, .init(session: 9, workbench: 3))
        XCTAssertEqual(center.reports[9]?.value?.session.id, 9)
        XCTAssertTrue(center.isPollingReport)
    }

    func testAppStateWiresTheWatchedWorkbenchAndTheAgentStates() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let runner = ScriptedReportRunner(Self.byFlags())
        let appState = AppState()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        defer {
            appState.sessionReportCenter?.stop()
            appState.sessionAgentStateCenter?.stop()
            appState.workbenchNotificationCenter?.stop()
            appState.workbenchesViewModel?.asks.stop()
        }
        let center = try XCTUnwrap(appState.sessionReportCenter)
        let vm = try XCTUnwrap(appState.workbenchesViewModel)

        XCTAssertNil(center.watchedWorkbenchID())
        vm.selectedWorkbenchID = 3
        XCTAssertEqual(center.watchedWorkbenchID(), 3)
        XCTAssertNil(center.agentState(9), "no session state read yet")
    }
}
