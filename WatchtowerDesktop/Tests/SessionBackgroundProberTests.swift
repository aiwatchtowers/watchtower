import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Answers `workbench session-probe` calls from a script, optionally holding
/// each call open until the test releases it. No process is spawned.
final class ScriptedProbeRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var gates: [AsyncGate] = []
    private var holding = false
    private var answer: @Sendable () throws -> Data

    init(_ answer: @escaping @Sendable () throws -> Data) {
        self.answer = answer
    }

    convenience init(json: String) {
        self.init { Data(json.utf8) }
    }

    var invocations: [[String]] { lock.withLock { calls } }

    /// From now on, each call waits for `release(_:)`.
    func hold() { lock.withLock { holding = true } }

    func answer(json: String) {
        lock.withLock { answer = { Data(json.utf8) } }
    }

    func answer(_ next: @escaping @Sendable () throws -> Data) {
        lock.withLock { answer = next }
    }

    /// Lets the `index`-th call return.
    func release(_ index: Int) {
        lock.withLock { gates[index] }.release()
    }

    func run(args: [String]) async throws -> Data {
        guard args.starts(with: ["workbench", "session-probe"]) else { return Data("{}".utf8) }
        let gate = AsyncGate()
        let held = lock.withLock {
            calls.append(args)
            gates.append(gate)
            return holding
        }
        if held { await gate.wait() }
        return try lock.withLock { answer }()
    }
}

enum ProbeAnswer {
    static func ran(_ outcome: String, ended: Bool = false) -> String {
        #"{"ok":true,"outcome":"\#(outcome)","ended":\#(ended),"agent_background_at":"x"}"#
    }

    static let failed = #"{"ok":false,"error":"database is locked"}"#
}

private struct ProbeLaunchFailure: LocalizedError {
    var errorDescription: String? { "launch failed" }
}

/// When the staleness probe runs, and the display-only over after failed
/// probes (spec 2026-10-10-session-background-agents §10, PROJ-11).
@MainActor
final class SessionBackgroundProberTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_790_000_000)
    /// The count's report: two seconds into the run.
    private var reported: Date { started.addingTimeInterval(2) }
    private var probers: [SessionBackgroundProber] = []

    override func setUp() {
        super.setUp()
        probers = []
    }

    override func tearDown() {
        // No probe outlives its test.
        probers.forEach { $0.stop() }
        super.tearDown()
    }

    private func makeProber(_ runner: ScriptedProbeRunner) -> SessionBackgroundProber {
        let prober = SessionBackgroundProber(runner: runner)
        probers.append(prober)
        return prober
    }

    private func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: started.addingTimeInterval(offset))
    }

    private func row(
        state: String = "waiting", projectID: Int64? = 7, count: Int? = 2, reportedAt offset: TimeInterval = 2
    ) -> SessionAgentStateRow {
        SessionAgentStateRow(id: 1, projectID: projectID, title: "Release work", agentState: state,
                             agentStateAt: stamp(1), workbenchName: "acme", agentBackground: count,
                             agentBackgroundAt: stamp(offset))
    }

    /// One center pass: the over set, the resolve, then the due probes.
    @discardableResult
    private func pass(
        _ prober: SessionBackgroundProber,
        _ rows: [SessionAgentStateRow],
        at now: Date,
        live: Set<Int64> = [1],
        run: Date? = nil
    ) -> SessionSwitcherPresentation.State? {
        let startedAt: [Int64: Date] = [1: run ?? started]
        let over = prober.displayOver(rows, liveIDs: live, startedAt: startedAt)
        let statuses = SessionAgentStatus.resolve(rows, liveIDs: live, startedAt: startedAt, now: now, displayOver: over)
        prober.probeDue(rows, statuses: statuses, startedAt: startedAt, now: now)
        return statuses[1]?.state
    }

    private func eventually(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            if ContinuousClock.now > deadline { return XCTFail("timed out: \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settled(_ prober: SessionBackgroundProber) async {
        await eventually("the probe settles") { !prober.isProbing(1) }
    }

    private func minutes(_ value: Double) -> Date { reported.addingTimeInterval(value * 60) }

    func testNoProbeBeforeThirtyMinutes() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.ran("busy"))
        let prober = makeProber(runner)
        pass(prober, [row()], at: reported.addingTimeInterval(30 * 60 - 1))
        await settled(prober)
        XCTAssertEqual(runner.invocations, [])

        pass(prober, [row()], at: minutes(30))
        await settled(prober)
        XCTAssertEqual(runner.invocations, [["workbench", "session-probe", "--workbench", "7", "--session", "1"]])
    }

    /// ask #142: `busy` keeps Agents working; the same count is asked again
    /// only after another 30 minutes of silence.
    func testABusyCountIsProbedAgainOnlyAfterAnotherThirtyMinutes() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.ran("busy"))
        let prober = makeProber(runner)
        XCTAssertEqual(pass(prober, [row()], at: minutes(30)), .live(.background, backgroundAgents: 2))
        await settled(prober)
        for minute in [31.0, 45, 59.9] {
            XCTAssertEqual(pass(prober, [row()], at: minutes(minute)), .live(.background, backgroundAgents: 2))
            await settled(prober)
        }
        XCTAssertEqual(runner.invocations.count, 1)
        pass(prober, [row()], at: minutes(60))
        await settled(prober)
        XCTAssertEqual(runner.invocations.count, 2)
    }

    /// Only a live workbench session showing Agents working with a count
    /// above zero is probed: never Needs approval, a stopped terminal, a
    /// standalone terminal, an earlier run's count or a count of zero.
    func testNoProbeOutsideAgentsWorking() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.ran("busy"))
        let prober = makeProber(runner)
        let late = minutes(90)
        XCTAssertEqual(pass(prober, [row(state: "approval")], at: late), .live(.needsApproval))
        XCTAssertEqual(pass(prober, [row(state: "working")], at: late), .live(.working))
        pass(prober, [row()], at: late, live: [])
        pass(prober, [row(projectID: nil)], at: late)
        pass(prober, [row()], at: late, run: started.addingTimeInterval(10))
        pass(prober, [row(count: 0)], at: late)
        pass(prober, [row(count: nil)], at: late)
        await settled(prober)
        XCTAssertEqual(runner.invocations, [])
    }

    func testOneProbeInFlightPerSession() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.ran("busy"))
        runner.hold()
        let prober = makeProber(runner)
        pass(prober, [row()], at: minutes(30))
        await eventually("the probe runs") { runner.invocations.count == 1 }
        pass(prober, [row()], at: minutes(31))
        pass(prober, [row()], at: minutes(120))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertTrue(prober.isProbing(1))
        runner.release(0)
        await settled(prober)
    }

    /// One probe that cannot run changes nothing on screen; it is tried
    /// again after a minute, not on the next pass.
    func testOneFailedProbeNeverEndsTheCount() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.failed)
        let prober = makeProber(runner)
        var settles = 0
        prober.onSettled = { settles += 1 }
        pass(prober, [row()], at: minutes(30))
        await settled(prober)
        XCTAssertEqual(pass(prober, [row()], at: minutes(30.9)), .live(.background, backgroundAgents: 2))
        await settled(prober)
        XCTAssertEqual(runner.invocations.count, 1, "no retry within the minute")
        XCTAssertEqual(settles, 0)

        runner.answer(json: ProbeAnswer.ran("busy"))
        XCTAssertEqual(pass(prober, [row()], at: minutes(31)), .live(.background, backgroundAgents: 2))
        await settled(prober)
        XCTAssertEqual(runner.invocations.count, 2, "retried after a minute")
        XCTAssertEqual(runner.invocations.filter { !$0.starts(with: ["workbench", "session-probe"]) }, [])
        XCTAssertEqual(pass(prober, [row()], at: minutes(32)), .live(.background, backgroundAgents: 2))
    }

    /// §10 (F24): two failed probes in a row for the same count show it
    /// over — Stopped, nothing written; shown over, it is probed again only
    /// every 30 minutes; a probe that runs, a new report or a new run
    /// clears it.
    func testTwoFailedProbesShowTheCountOverWithoutAWrite() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.failed)
        let prober = makeProber(runner)
        var settles = 0
        prober.onSettled = { settles += 1 }
        pass(prober, [row()], at: minutes(30))
        await settled(prober)
        runner.answer { throw ProbeLaunchFailure() }
        pass(prober, [row()], at: minutes(31))
        await settled(prober)
        XCTAssertEqual(settles, 1, "the over is shown at once")
        XCTAssertEqual(pass(prober, [row()], at: minutes(31.5)), .live(.stopped))

        // Shown over, the count backs off to the 30-minute cadence: no
        // probe a minute later, nor just before the 30 minutes are up.
        runner.answer(json: ProbeAnswer.ran("busy"))
        pass(prober, [row()], at: minutes(32))
        XCTAssertFalse(prober.isProbing(1), "no 60 s retry once shown over")
        pass(prober, [row()], at: minutes(60.9))
        XCTAssertFalse(prober.isProbing(1))
        XCTAssertEqual(runner.invocations.count, 2)

        // Still probed at that cadence, so a probe that runs clears it.
        pass(prober, [row()], at: minutes(61))
        await settled(prober)
        XCTAssertEqual(runner.invocations.count, 3)
        XCTAssertEqual(settles, 2)
        XCTAssertEqual(pass(prober, [row()], at: minutes(61.5)), .live(.background, backgroundAgents: 2))

        // Over again at the count's next silence; a new report clears it.
        runner.answer(json: ProbeAnswer.failed)
        pass(prober, [row()], at: minutes(91))
        await settled(prober)
        pass(prober, [row()], at: minutes(92))
        await settled(prober)
        XCTAssertEqual(pass(prober, [row()], at: minutes(92.5)), .live(.stopped))
        XCTAssertEqual(pass(prober, [row(reportedAt: 92 * 60)], at: minutes(92.5)),
                       .live(.background, backgroundAgents: 2), "a new report is a new count")
        XCTAssertEqual(pass(prober, [row()], at: minutes(92.5)), .live(.background, backgroundAgents: 2),
                       "the old count's failures are forgotten: it is probed afresh")
        await settled(prober)

        // Over once more; a new run clears it.
        pass(prober, [row()], at: minutes(93.5))
        await settled(prober)
        XCTAssertEqual(pass(prober, [row()], at: minutes(94)), .live(.stopped))
        XCTAssertEqual(pass(prober, [row()], at: minutes(94), run: started.addingTimeInterval(10)), .live(.running))
        XCTAssertEqual(prober.displayOver([row()], liveIDs: [1], startedAt: [1: started]), [],
                       "the earlier run's failures are forgotten")
        XCTAssertTrue(runner.invocations.allSatisfy { $0.starts(with: ["workbench", "session-probe"]) },
                      "the Desktop only probes; Go is the writer")
    }

    /// A probe that ended the count asks the center for a read; one that
    /// left it alone does not.
    func testAnEndedCountAsksForARead() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.ran("idle", ended: false))
        let prober = makeProber(runner)
        var settles = 0
        prober.onSettled = { settles += 1 }
        pass(prober, [row()], at: minutes(30))
        await settled(prober)
        XCTAssertEqual(settles, 0, "a report landed first: the poll shows it")

        runner.answer(json: ProbeAnswer.ran("gone", ended: true))
        pass(prober, [row(reportedAt: 3)], at: minutes(31))
        await settled(prober)
        XCTAssertEqual(settles, 1)
    }

    /// `stop()` cancels the probe in flight; its late answer applies nothing.
    func testStopCancelsTheProbe() async {
        let runner = ScriptedProbeRunner(json: ProbeAnswer.failed)
        runner.hold()
        let prober = makeProber(runner)
        var settles = 0
        prober.onSettled = { settles += 1 }
        pass(prober, [row()], at: minutes(30))
        await eventually("the probe runs") { runner.invocations.count == 1 }
        prober.stop()
        XCTAssertFalse(prober.isProbing(1))
        runner.release(0)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(settles, 0)
        XCTAssertEqual(prober.displayOver([row()], liveIDs: [1], startedAt: [1: started]), [],
                       "the cancelled failure is not counted")
        pass(prober, [row()], at: minutes(30.5))
        await eventually("a stopped prober forgot the count: it probes afresh") { runner.invocations.count == 2 }
        runner.release(1)
        await settled(prober)
    }
}
