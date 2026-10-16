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

private struct ScriptedFailure: LocalizedError {
    let errorDescription: String?
}

@MainActor
final class AgentAnalyticsCenterTests: XCTestCase {
    private var centers: [AgentAnalyticsCenter] = []

    override func tearDown() {
        centers.forEach { $0.stop() }
        super.tearDown()
    }

    private func makeCenter(
        _ runner: ScriptedAgentsRunner, interval: Duration = .seconds(3600)
    ) -> AgentAnalyticsCenter {
        let center = AgentAnalyticsCenter(runner: runner, interval: interval)
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

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
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
        await settle()
        XCTAssertEqual(runner.invocations.count, 1, "the same period again runs nothing")
    }

    func testPeriodChangeRunsAtOnceAndAllMapsToDaysZero() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner)

        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 }
        center.show(workbench: 3, period: .all)
        await waitUntil { runner.invocations.count == 2 }

        XCTAssertEqual(runner.invocations[0].suffix(2), ["--days", "7"])
        XCTAssertEqual(runner.invocations[1].suffix(2), ["--days", "0"])
    }

    func testTickRunsOnlyWhileTheTabIsOnScreen() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner, interval: .milliseconds(20))
        var onScreen = false
        center.isTabOnScreen = { onScreen }

        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 }
        await settle()
        XCTAssertEqual(runner.invocations.count, 1, "no tick run while the tab is off screen")

        onScreen = true
        await waitUntil { runner.invocations.count >= 2 }
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

    func testOneInFlightAndOneQueued() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        runner.hold()
        let center = makeCenter(runner)

        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 1 }
        center.show(workbench: 3, period: .month)
        center.show(workbench: 3, period: .all)
        await settle()
        XCTAssertEqual(runner.invocations.count, 1, "asking while a run is in flight starts none")

        runner.release(0)
        await waitUntil { runner.invocations.count == 2 }
        runner.release(1)
        await settle()
        XCTAssertEqual(runner.invocations.count, 2, "two asks queue one rerun")
        XCTAssertEqual(runner.invocations[1].suffix(2), ["--days", "0"], "the rerun reads the latest period")
    }

    func testHideStopsTheTicks() async {
        let runner = ScriptedAgentsRunner(Self.byFlags())
        let center = makeCenter(runner, interval: .milliseconds(20))
        center.isTabOnScreen = { true }
        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count >= 2 }

        center.hide(workbench: 3)
        XCTAssertFalse(center.isPolling)
        await settle()
        let count = runner.invocations.count
        try? await Task.sleep(for: .milliseconds(100))
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

        center.stop()
        runner.release(0)
        await settle()

        XCTAssertNil(center.overviews[3])
        XCTAssertFalse(center.isPolling)
    }
}
