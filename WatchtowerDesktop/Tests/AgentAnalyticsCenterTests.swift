import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `agents` calls from a script, optionally holding each call open
/// until the test releases it. No process is spawned.
private final class ScriptedAgentsRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var gates: [AsyncGate] = []
    private var holding = false
    private var answer: @Sendable ([String]) throws -> Data

    init(_ answer: @escaping @Sendable ([String]) throws -> Data) {
        self.answer = answer
    }

    var invocations: [[String]] { lock.withLock { calls } }

    func hold() { lock.withLock { holding = true } }

    func answer(_ next: @escaping @Sendable ([String]) throws -> Data) {
        lock.withLock { answer = next }
    }

    func release(_ index: Int) {
        lock.withLock { gates[index] }.release()
    }

    func run(args: [String]) async throws -> Data {
        guard args.starts(with: ["agents"]) else { return Data("{}".utf8) }
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

/// The center's waits between ticks, parked until the test ends them: a tick
/// comes when the test says so, never on a clock.
private final class ManualTicks: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var started = 0

    /// Every wait started so far, ended or not.
    var waits: Int { lock.withLock { started } }

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                started += 1
                parked.append(continuation)
            }
        }
    }

    /// Ends every wait parked now: one tick.
    func tick() {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { parked = [] }
            return parked
        }
        due.forEach { $0.resume() }
    }
}

private struct ScriptedFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
final class AgentAnalyticsCenterTests: XCTestCase {
    private var centers: [AgentAnalyticsCenter] = []
    private var ticks: ManualTicks!

    override func setUp() {
        super.setUp()
        ticks = ManualTicks()
    }

    override func tearDown() {
        centers.forEach { $0.stop() }
        ticks.tick() // a stopped loop ends at its next wake
        super.tearDown()
    }

    private func makeCenter(_ runner: ScriptedAgentsRunner) -> AgentAnalyticsCenter {
        let ticks: ManualTicks = self.ticks
        let center = AgentAnalyticsCenter(runner: runner) { await ticks.sleep($0) }
        centers.append(center)
        return center
    }

    nonisolated private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/<this file>
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/\(name).json")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    nonisolated private static func byFlags() -> @Sendable ([String]) throws -> Data {
        { args in
            args.contains("--session") ? fixture("agent-report-session") : fixture("agent-report-overview")
        }
    }

    /// Yields the main actor until `condition` holds. No deadline: the wait
    /// ends on the runner's and the center's state, never on a clock — a
    /// wait that never ends is a hang the lane watchdog reports.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        while !condition() { await Task.yield() }
    }

    /// Waits for every run in flight to end, a queued rerun included.
    private func settle(_ center: AgentAnalyticsCenter) async {
        while let run = center.inFlightTasks.first { await run.value }
    }

    /// One tick: the loop's wait ends, and the next wait starts.
    private func tick() async {
        let waits = ticks.waits
        ticks.tick()
        await waitUntil { self.ticks.waits == waits + 1 }
    }

    func testShowRunsOnceAndSchedules() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)

        center.show(workbench: 3, period: .month)
        await waitUntil { center.overviews[3]?.value != nil }

        XCTAssertEqual(runner.invocations, [["agents", "report", "--workbench", "3", "--json", "--days", "30"]])
        XCTAssertNil(center.overviews[3]?.error)
        XCTAssertTrue(center.isPolling)

        center.show(workbench: 3, period: .month)
        XCTAssertTrue(center.inFlightTasks.isEmpty, "the same period again starts no run")
        await settle(center)
        XCTAssertEqual(runner.invocations.count, 1, "the same period again runs nothing")
    }

    func testPeriodChangeRunsAtOnceWithItsDays() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)

        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 }
        center.show(workbench: 3, period: .day)
        await waitUntil { runner.invocations.count == 2 }

        XCTAssertEqual(runner.invocations[0].suffix(2), ["--days", "7"])
        XCTAssertEqual(runner.invocations[1].suffix(2), ["--days", "1"])
    }

    func testTickRunsOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)
        var onScreen = false
        center.isTabOnScreen = { onScreen }

        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 && self.ticks.waits == 1 }
        await settle(center)
        await tick()
        XCTAssertTrue(center.inFlightTasks.isEmpty, "the tick started no run")
        XCTAssertEqual(runner.invocations.count, 1, "no tick run while the tab is off screen")

        onScreen = true
        await tick()
        await waitUntil { runner.invocations.count == 2 }
    }

    func testFailureKeepsTheLastValueAndSetsError() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { center.overviews[3]?.value != nil }
        let good = center.overviews[3]?.value

        runner.answer { _ in throw ScriptedFailure(errorDescription: "boom\nsecond line") }
        center.show(workbench: 3, period: .month)
        await waitUntil { center.overviews[3]?.error != nil }

        XCTAssertEqual(center.overviews[3]?.value, good)
        XCTAssertEqual(center.overviews[3]?.error, "boom")
        XCTAssertEqual(center.overviews[3]?.isStale, true)
    }

    /// The fixture with some keys replaced.
    nonisolated private static func overview(_ changes: [String: Any]) -> Data {
        guard var json = (try? JSONSerialization.jsonObject(with: fixture("agent-report-overview"))) as? [String: Any]
        else { return Data() }
        json.merge(changes) { $1 }
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    /// A run that brings the same report back — Go moves `since`/`until`
    /// with the clock on every run — assigns nothing, so the pane is not
    /// redrawn every 60 s; a changed report is assigned.
    func testCenterSkipsEqualOverview() async throws {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)
        var onScreen = false
        center.isTabOnScreen = { onScreen }
        center.show(workbench: 3, period: .week)
        await waitUntil { center.overviews[3]?.value != nil && self.ticks.waits == 1 }
        await settle(center)

        var changes = 0
        withObservationTracking { _ = center.overviews } onChange: { changes += 1 }
        let later = Self.overview(["since": "2026-10-01T00:01:00Z", "until": "2026-10-08T00:01:00Z"])
        runner.answer { _ in later }
        onScreen = true
        await tick()
        await settle(center)
        await tick()
        await settle(center)
        onScreen = false
        XCTAssertEqual(runner.invocations.count, 3)
        XCTAssertEqual(changes, 0, "only the stamps moved: nothing is assigned")
        XCTAssertEqual(center.overviews[3]?.value?.until, "2026-10-08T00:00:00Z", "the shown report is kept")

        let changed = Self.overview(["old_format_sessions": 7])
        runner.answer { _ in changed }
        onScreen = true
        await tick()
        await waitUntil { center.overviews[3]?.value?.oldFormatSessions == 7 }
        onScreen = false
        XCTAssertGreaterThan(changes, 0, "a changed report is assigned")
    }

    /// The same content over another period is assigned: the pane reads
    /// the period off the report ("Updating…" until it matches).
    func testCenterAssignsTheSameContentForAnotherPeriod() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { center.overviews[3]?.value != nil }

        let month = Self.overview(["since": "2026-09-08T00:00:00Z"])
        runner.answer { _ in month }
        center.show(workbench: 3, period: .month)
        await waitUntil { center.overviews[3]?.value?.since == "2026-09-08T00:00:00Z" }
    }

    func testOneInFlightAndOneQueued() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 }
        let first = center.inFlightTasks
        center.show(workbench: 3, period: .month)
        center.show(workbench: 3, period: .day)
        XCTAssertEqual(center.inFlightTasks, first, "asking while a run is in flight starts none")
        XCTAssertEqual(runner.invocations.count, 1, "asking while a run is in flight starts none")

        runner.release(0)
        await waitUntil { runner.invocations.count == 2 }
        runner.release(1)
        await settle(center)
        XCTAssertEqual(runner.invocations.count, 2, "two asks queue one rerun")
        XCTAssertEqual(runner.invocations[1].suffix(2), ["--days", "1"], "the rerun reads the latest period")
    }

    func testHideStopsTheTicks() async throws {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)
        center.isTabOnScreen = { true }
        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 && self.ticks.waits == 1 }
        await settle(center)
        await tick()
        await waitUntil { runner.invocations.count == 2 }

        let loop = try XCTUnwrap(center.loop)
        center.hide(workbench: 3)
        XCTAssertFalse(center.isPolling)
        await settle(center)
        let count = runner.invocations.count
        ticks.tick()
        await loop.value // the cancelled loop wakes and ends without a tick
        XCTAssertTrue(center.inFlightTasks.isEmpty)
        XCTAssertEqual(runner.invocations.count, count)
    }

    func testLoadSessionDecodesTheDetailAndKeepsItStaleOnFailure() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)

        center.loadSession(workbench: 3, uuid: "u-1")
        await waitUntil { center.sessions["u-1"]?.value != nil }
        XCTAssertEqual(runner.invocations, [["agents", "report", "--workbench", "3", "--json", "--session", "u-1"]])

        runner.answer { _ in throw ScriptedFailure(errorDescription: "gone") }
        center.loadSession(workbench: 3, uuid: "u-1")
        await waitUntil { center.sessions["u-1"]?.error != nil }
        XCTAssertNotNil(center.sessions["u-1"]?.value)
    }

    func testTurnOnEnablesThenReloadsAndFlagsEnabling() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        let turning = Task { await center.turnOn(workbench: 3) }
        await waitUntil { runner.invocations.count == 1 }
        XCTAssertEqual(center.enabling, [3])
        XCTAssertEqual(runner.invocations[0], ["agents", "enable", "--workbench", "3", "--json"])

        runner.release(0)
        await waitUntil { runner.invocations.count == 2 }
        XCTAssertEqual(Array(runner.invocations[1].prefix(2)), ["agents", "report"])
        runner.release(1)
        await turning.value

        XCTAssertTrue(center.enabling.isEmpty)
        XCTAssertNotNil(center.overviews[3]?.value)
    }

    func testTurnOnFailureSurfacesTheErrorAndClearsEnabling() async {
        let runner = ScriptedAgentsRunner { _ in throw ScriptedFailure(errorDescription: "no history") }
        let center = makeCenter(runner)

        await center.turnOn(workbench: 3)

        XCTAssertTrue(center.enabling.isEmpty)
        XCTAssertEqual(center.overviews[3]?.error, "no history")
        XCTAssertEqual(runner.invocations.count, 1, "no reload after a failed enable")
    }

    func testStopCancelsRunsAndDropsTheirResults() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 }

        let runs = center.inFlightTasks
        center.stop()
        runner.release(0)
        for run in runs { await run.value } // the cancelled run's late answer has landed

        XCTAssertNil(center.overviews[3])
        XCTAssertFalse(center.isPolling)
    }
}
