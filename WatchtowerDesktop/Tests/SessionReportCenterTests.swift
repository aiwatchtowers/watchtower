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
    private var waiters: [(count: Int, matching: @Sendable ([String]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []
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

    /// Returns once `count` recorded calls match `matching`.
    func untilCalls(_ count: Int, matching: @escaping @Sendable ([String]) -> Bool = { _ in true }) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let met = lock.withLock {
                if calls.filter(matching).count >= count { return true }
                waiters.append((count, matching, continuation))
                return false
            }
            if met { continuation.resume() }
        }
    }

    func run(args: [String]) async throws -> Data {
        guard args.starts(with: ["workbench", "session-report"]) else { return Data("{}".utf8) }
        let gate = AsyncGate()
        let (held, ready) = lock.withLock {
            calls.append(args)
            gates.append(gate)
            let calls = calls
            let ready = waiters.filter { calls.filter($0.matching).count >= $0.count }.map(\.continuation)
            waiters.removeAll { calls.filter($0.matching).count >= $0.count }
            return (holding, ready)
        }
        ready.forEach { $0.resume() }
        if held { await gate.wait() }
        return try lock.withLock { answer }(args)
    }
}

/// A stand-in for `SessionAgentStateCenter.statuses`, observable the same way.
@MainActor
@Observable
private final class FakeAgentStates {
    var states: [Int64: SessionSwitcherPresentation.State] = [:]
    /// Counts the center's reads; not observed, so the center's own
    /// tracking never sees it.
    @ObservationIgnored let reads = ReadLog()
}

/// How often the center read an agent state, with a wait for the next read.
@MainActor
private final class ReadLog {
    private(set) var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func until(_ target: Int) async {
        if count >= target { return }
        await withCheckedContinuation { waiters.append((target, $0)) }
    }
}

/// The center's loop sleeps, ended by hand: `tick` wakes the loop parked at
/// an interval and returns once that loop parked again (its tick's work is
/// done). A cancelled sleep returns at once.
@MainActor
private final class LoopClock {
    private var parked: [UUID: (interval: Duration, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var arrivals: [(interval: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var cancelledSleeps = 0
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []

    nonisolated var sleep: @Sendable (Duration) async -> Void {
        { [self] interval in await self.park(interval) }
    }

    private func park(_ interval: Duration) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    // Cancelled before it parked: still a sleep its cancel ended.
                    sleepCancelled()
                    return continuation.resume()
                }
                parked[id] = (interval, continuation)
                let ready = arrivals.filter { $0.interval == interval }
                arrivals.removeAll { $0.interval == interval }
                ready.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let sleeper = parked.removeValue(forKey: id) else { return }
        sleeper.continuation.resume()
        sleepCancelled()
    }

    private func sleepCancelled() {
        cancelledSleeps += 1
        cancelWaiters.forEach { $0.resume() }
        cancelWaiters = []
    }

    /// Returns once a loop sleeps at `interval`.
    func untilParked(_ interval: Duration) async {
        if parked.values.contains(where: { $0.interval == interval }) { return }
        await withCheckedContinuation { arrivals.append((interval, $0)) }
    }

    func tick(_ interval: Duration) async {
        await untilParked(interval)
        guard let id = parked.first(where: { $0.value.interval == interval })?.key,
              let sleeper = parked.removeValue(forKey: id) else { return }
        sleeper.continuation.resume()
        await untilParked(interval)
    }

    /// Returns once a parked sleep was ended by its task's cancel.
    func untilASleepIsCancelled() async {
        if cancelledSleeps > 0 { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }
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

    private static let summaryTick: Duration = .seconds(15)
    private static let reportTick: Duration = .seconds(30)

    /// The loops sleep on `clock`, never on time: they tick only when a
    /// test ticks them.
    private func makeCenter(_ runner: ScriptedReportRunner, clock: LoopClock? = nil) -> SessionReportCenter {
        let clock = clock ?? LoopClock()
        let center = SessionReportCenter(
            runner: runner, summaryInterval: Self.summaryTick, reportInterval: Self.reportTick,
            notificationCenter: activations, sleep: clock.sleep
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

    // MARK: - Summary

    func testSummaryPollRunsOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        var onScreen = false
        center.isTabOnScreen = { onScreen }
        center.watchedWorkbenchID = { 3 }

        center.pollSummaries()
        await center.runsSettled()
        XCTAssertEqual(runner.invocations, [], "no run while the tab is not on screen")

        onScreen = true
        center.pollSummaries()
        await untilObserved { center.summaries[3]?.value != nil }
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
        await center.runsSettled()
        XCTAssertEqual(runner.invocations, [])
    }

    func testSummaryLoopTicksAtItsIntervalWhileTheTabIsOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let clock = LoopClock()
        let center = makeCenter(runner, clock: clock)
        var onScreen = false
        center.isTabOnScreen = { onScreen }
        center.watchedWorkbenchID = { 3 }
        XCTAssertEqual(SessionReportCenter.summaryInterval, .seconds(15))

        center.start()
        XCTAssertTrue(center.isPollingSummaries)
        for _ in 0..<3 { await clock.tick(Self.summaryTick) }
        await center.runsSettled()
        XCTAssertEqual(runner.invocations, [], "ticks while the tab is hidden run nothing")

        onScreen = true
        await clock.tick(Self.summaryTick)
        await center.runsSettled()
        await clock.tick(Self.summaryTick)
        await runner.untilCalls(2)

        center.stop()
        XCTAssertFalse(center.isPollingSummaries)
        await clock.untilASleepIsCancelled()
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 2, "no tick after stop: the loop's sleep ended by its cancel")
    }

    func testActivationRefreshesTheWatchedWorkbench() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.watchedWorkbenchID = { 5 }
        center.start()

        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await untilObserved { center.summaries[5]?.value != nil }
        XCTAssertEqual(runner.invocations.map { $0[3] }, ["5"])
    }

    // MARK: - Full report

    func testShowRunsTheReportAndItsLoopRunsWhileShown() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let clock = LoopClock()
        let center = makeCenter(runner, clock: clock)
        center.isTabOnScreen = { true }
        XCTAssertEqual(SessionReportCenter.reportInterval, .seconds(30))

        center.show(session: 9, workbench: 3)
        XCTAssertEqual(center.shown, .init(session: 9, workbench: 3))
        XCTAssertTrue(center.isPollingReport)
        await untilObserved { center.reports[9]?.value != nil }
        XCTAssertEqual(runner.invocations.first, [
            "workbench", "session-report", "--workbench", "3", "--session", "9", "--json"
        ])
        XCTAssertEqual(center.reports[9]?.value?.session.id, 9)
        await clock.tick(Self.reportTick)
        await center.runsSettled()
        await clock.tick(Self.reportTick)
        await runner.untilCalls(3)

        center.hide(session: 9)
        XCTAssertNil(center.shown)
        XCTAssertFalse(center.isPollingReport)
        await clock.untilASleepIsCancelled()
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 3, "no run once hidden: the loop's sleep ended by its cancel")
        XCTAssertNotNil(center.reports[9]?.value, "the last report stays for the next show")
    }

    func testReportTicksRunOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let clock = LoopClock()
        let center = makeCenter(runner, clock: clock)
        var onScreen = false
        center.isTabOnScreen = { onScreen }

        center.show(session: 9, workbench: 3)
        await untilObserved { center.reports[9]?.value != nil }
        XCTAssertEqual(runner.invocations.count, 1, "show runs whatever the tab")
        for _ in 0..<3 { await clock.tick(Self.reportTick) }
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 1, "ticks while the tab is hidden run nothing")
        XCTAssertTrue(center.isPollingReport, "the loop keeps ticking, gated")

        onScreen = true
        await clock.tick(Self.reportTick)
        await center.runsSettled()
        await clock.tick(Self.reportTick)
        await runner.untilCalls(3)

        onScreen = false
        await center.runsSettled()
        for _ in 0..<3 { await clock.tick(Self.reportTick) }
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 3, "hidden again: the ticks stop running")
    }

    func testAnAgentStateChangeRerunsWhileTheTabIsHidden() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)
        let agents = FakeAgentStates()
        agents.states[9] = .live(.working)
        center.agentState = { agents.states[$0] }
        center.isTabOnScreen = { false }

        center.show(session: 9, workbench: 3)
        await runner.untilCalls(1)
        agents.states[9] = .live(.stopped)
        await runner.untilCalls(2)
    }

    nonisolated private static let isReportRun: @Sendable ([String]) -> Bool = { $0.contains("--session") }

    private func reportRuns(_ runner: ScriptedReportRunner) -> Int {
        runner.invocations.filter(Self.isReportRun).count
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
        await runner.untilCalls(1, matching: Self.isReportRun)

        onScreen = false
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await center.runsSettled()
        XCTAssertEqual(reportRuns(runner), 1, "going off screen runs nothing")
        onScreen = true
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await runner.untilCalls(2, matching: Self.isReportRun)

        onScreen = false
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await center.runsSettled()
        onScreen = true
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await runner.untilCalls(3, matching: Self.isReportRun)
        await center.runsSettled()
        XCTAssertEqual(reportRuns(runner), 3)
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
        await runner.untilCalls(1, matching: Self.isReportRun)

        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        activations.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        await center.runsSettled()
        XCTAssertEqual(reportRuns(runner), 1)

        center.hide(session: 9)
        activations.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await center.runsSettled()
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
        await runner.untilCalls(1, matching: Self.isReportRun)

        for _ in 0..<3 {
            onScreen = false
            center.screenMayHaveChanged()
            onScreen = true
            center.screenMayHaveChanged()
        }
        // The first run is held: every rerun can only have been queued.
        XCTAssertEqual(reportRuns(runner), 1, "the run in flight is not doubled")
        runner.release(0)
        await runner.untilCalls(2, matching: Self.isReportRun)
        runner.release(1)
        await center.runsSettled()
        XCTAssertEqual(reportRuns(runner), 2, "one queued rerun, not three")
    }

    func testShowingTheSameSessionAgainStartsNoSecondRun() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await untilObserved { center.reports[9]?.value != nil }
        center.show(session: 9, workbench: 3)
        await center.runsSettled()
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
        center.agentState = { agents.reads.record(); return agents.states[$0] }

        center.show(session: 9, workbench: 3)
        await untilObserved { center.reports[9]?.value != nil }
        XCTAssertEqual(runner.invocations.count, 1)

        // Every change is followed by a read of the state; what that read
        // decides is started before the test runs again.
        var reads = agents.reads.count
        agents.states[4] = .live(.stopped)
        await agents.reads.until(reads + 1)
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 1, "another session's change reruns nothing")

        reads = agents.reads.count
        agents.states[9] = .live(.needsApproval)
        await agents.reads.until(reads + 1)
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 2, "one rerun per change")

        agents.states[9] = .live(.stopped)
        await runner.untilCalls(3)

        center.hide(session: 9)
        reads = agents.reads.count
        agents.states[9] = .live(.working)
        // The change hops to the main actor before it is followed; a turn
        // queued after that hop runs once it has (the main queue is FIFO).
        await Task { @MainActor in }.value
        await center.runsSettled()
        // Hidden: the follow was ended, so the change is not even read.
        XCTAssertEqual(agents.reads.count, reads, "a hidden session's change is not read")
        XCTAssertEqual(runner.invocations.count, 3, "a hidden session's change reruns nothing")
    }

    // MARK: - Concurrency

    func testOneRunInFlightPlusOneQueuedRerunPerWorkbench() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.refresh(workbench: 3)
        await runner.untilCalls(1)
        center.refresh(workbench: 3)
        center.refresh(workbench: 3)
        center.refresh(workbench: 3)
        center.refresh(workbench: 4)
        await runner.untilCalls(2)
        // Both runs are held: the reruns of 3 can only have been queued.
        XCTAssertEqual(runner.invocations.map { $0[3] }, ["3", "4"], "another workbench runs in parallel; the reruns wait")

        runner.release(0)
        await runner.untilCalls(3)
        XCTAssertEqual(runner.invocations[2][3], "3", "exactly one queued rerun")
        runner.release(2)
        runner.release(1)
        await center.runsSettled()
        XCTAssertEqual(runner.invocations.count, 3, "the queue held one rerun, not three")
    }

    func testTheReportRunAndTheSummaryRunDoNotQueueBehindEachOther() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        center.refresh(workbench: 3)
        await runner.untilCalls(2)
        runner.release(0)
        runner.release(1)
    }

    // MARK: - Failures

    func testAFailedSummaryKeepsTheLastValueMarkedStale() async {
        let runner = ScriptedReportRunner(Self.byFlags(done: 14))
        let center = makeCenter(runner)

        center.refresh(workbench: 3)
        await untilObserved { center.summaries[3]?.value != nil }

        runner.answer { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "unknown workbench 3\nmore detail") }
        center.refresh(workbench: 3)
        await untilObserved { center.summaries[3]?.isStale == true }
        XCTAssertEqual(center.summaries[3]?.value?[7]?.done, 14, "the last good rows stay")
        XCTAssertEqual(center.summaries[3]?.error, "watchtower exited with error: unknown workbench 3")
        if let summary = center.summaries[3]?.value?[7] {
            XCTAssertEqual(SessionReportPresentation.rowCaption(summary, stale: true), "#314 · 14/15 · PR #147 open · stale")
        }

        runner.answer(Self.byFlags(done: 15))
        center.refresh(workbench: 3)
        await untilObserved { center.summaries[3]?.isStale == false }
        XCTAssertEqual(center.summaries[3]?.value?[7]?.done, 15)
        XCTAssertNil(center.summaries[3]?.error)
    }

    func testAFailedReportKeepsTheLastReportMarkedStale() async {
        let runner = ScriptedReportRunner(Self.byFlags(done: 2))
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await untilObserved { center.reports[9]?.value != nil }

        runner.answer { _ in Data("not json".utf8) }
        center.refreshShownReport()
        await untilObserved { center.reports[9]?.isStale == true }
        XCTAssertEqual(center.reports[9]?.value?.progress.done, 2, "the last good report stays")
        XCTAssertNotNil(center.reports[9]?.error)
    }

    func testAFirstRunFailureHasNoValueButAnErrorLine() async {
        let runner = ScriptedReportRunner { _ in throw ScriptedFailure(errorDescription: "watchtower binary not found.") }
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await untilObserved { center.reports[9]?.error != nil }
        XCTAssertNil(center.reports[9]?.value)
        XCTAssertEqual(center.reports[9]?.error, "watchtower binary not found.")
    }

    // MARK: - Session switch

    func testASessionSwitchCancelsNothingAndDropsTheOldSessionsResult() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await runner.untilCalls(1)
        center.show(session: 10, workbench: 3)
        XCTAssertEqual(runner.invocations.count, 1, "the old run is not cancelled; the new one waits behind it")

        runner.release(0)
        await runner.untilCalls(2)
        XCTAssertNil(center.reports[9], "the old session's late result is dropped")
        XCTAssertEqual(runner.invocations[1][5], "10", "the queued rerun is for the session now shown")

        runner.release(1)
        await untilObserved { center.reports[10]?.value != nil }
        XCTAssertEqual(center.reports[10]?.value?.session.id, 10)
        XCTAssertNil(center.reports[9])
    }

    func testAFailureOfTheOldSessionIsDroppedToo() async {
        let runner = ScriptedReportRunner { _ in throw ScriptedFailure(errorDescription: "boom") }
        runner.hold()
        let center = makeCenter(runner)

        center.show(session: 9, workbench: 3)
        await runner.untilCalls(1)
        center.hide(session: 9)
        runner.release(0)
        await center.runsSettled()
        XCTAssertNil(center.reports[9])
        XCTAssertEqual(runner.invocations.count, 1)
    }

    func testStopCancelsTheRunsInFlight() async {
        let runner = ScriptedReportRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.refresh(workbench: 3)
        await runner.untilCalls(1)
        center.refresh(workbench: 3)
        center.stop()
        runner.release(0)
        await center.runsSettled()
        XCTAssertNil(center.summaries[3], "a cancelled run's result is not applied")
        XCTAssertEqual(runner.invocations.count, 1, "the queued rerun is dropped")

        // The center works again after a stop.
        center.refresh(workbench: 3)
        await runner.untilCalls(2)
        runner.release(1)
        await untilObserved { center.summaries[3]?.value != nil }
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
        await untilObserved { center.reports[9]?.value != nil }

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
