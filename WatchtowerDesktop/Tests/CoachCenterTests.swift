import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// Answers `coach` calls from a script, optionally holding calls open.
private final class ScriptedCoachRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var stdins: [String] = []
    private var gates: [AsyncGate] = []
    private var holding = false
    private var cancelledAtReturn: [Bool] = []
    private var script: @Sendable ([String]) throws -> Data

    init(_ script: @escaping @Sendable ([String]) throws -> Data) { self.script = script }

    var invocations: [[String]] { lock.withLock { calls } }
    var stdinTexts: [String] { lock.withLock { stdins } }
    var cancellations: [Bool] { lock.withLock { cancelledAtReturn } }

    func hold() { lock.withLock { holding = true } }
    func answer(_ next: @escaping @Sendable ([String]) throws -> Data) { lock.withLock { script = next } }
    func release(_ index: Int) { lock.withLock { gates[index] }.release() }

    func run(args: [String]) async throws -> Data { try await record(args, stdin: nil) }
    func run(args: [String], stdin: Data) async throws -> Data {
        try await record(args, stdin: String(bytes: stdin, encoding: .utf8) ?? "")
    }

    private func record(_ args: [String], stdin: String?) async throws -> Data {
        let gate = AsyncGate()
        let held = lock.withLock {
            calls.append(args)
            if let stdin { stdins.append(stdin) }
            gates.append(gate)
            return holding
        }
        if held { await gate.wait() }
        defer { lock.withLock { cancelledAtReturn.append(Task.isCancelled) } }
        return try lock.withLock { script }(args)
    }
}

@MainActor
final class CoachCenterTests: XCTestCase {
    private var centers: [CoachCenter] = []

    override func tearDown() {
        centers.forEach { $0.stop() }
        super.tearDown()
    }

    private func makeCenter(_ runner: ScriptedCoachRunner) -> CoachCenter {
        let center = CoachCenter(runner: runner, interval: .seconds(3600))
        centers.append(center)
        return center
    }

    nonisolated private static func fixture(_ name: String) -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Core/Fixtures/\(name).json")
        return (try? Data(contentsOf: url)) ?? Data()
    }

    nonisolated private static func standard() -> @Sendable ([String]) throws -> Data {
        { args in
            switch args.dropFirst().first {
            case "status": return fixture("coach-status")
            case "proposals": return fixture("coach-proposals")
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
    }

    nonisolated private static func failure(_ json: String) -> Error {
        CLIRunnerError.nonZeroExit(code: 1, stderr: json + "\ncoach: failed\n")
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

    func testShowLoadsStatusAndProposals() async {
        let runner = ScriptedCoachRunner(Self.standard())
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { center.status[3]?.value != nil && center.proposals?.value != nil }
        let calls = runner.invocations
        XCTAssertTrue(calls.contains(["coach", "status", "--workbench", "3", "--days", "7", "--json"]))
        XCTAssertTrue(calls.contains(["coach", "proposals", "--status", "all", "--json"]))
    }

    func testPeriodChangeDropsStaleStatus() async {
        let runner = ScriptedCoachRunner(Self.standard())
        runner.hold()
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { runner.invocations.count == 2 }
        center.show(workbench: 3, period: .day)
        // Release the 7-day status (the first call) after the switch.
        guard let index = runner.invocations.firstIndex(where: { $0.contains("status") }) else { return XCTFail("no status call") }
        runner.release(index)
        await settle()
        XCTAssertNil(center.status[3]?.value, "a 7-day reply after a switch to 1 day is not stored")
        for i in 0..<runner.invocations.count where i != index {
            if i < runner.invocations.count { runner.release(i) }
        }
        await waitUntil { runner.invocations.contains { $0.contains("status") && $0.contains("1") } }
    }

    func testStaleAcceptClosesCardAndReloads() async {
        let runner = ScriptedCoachRunner(Self.standard())
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { center.proposals?.value != nil }
        runner.answer { args in
            if args.dropFirst().first == "accept" {
                throw Self.failure(#"{"ok":false,"error":"stale","code":"stale"}"#)
            }
            return try Self.standard()(args)
        }
        let before = runner.invocations.filter { $0.contains("proposals") }.count
        await center.accept(7, editedText: nil)
        XCTAssertEqual(center.cardErrors[7], "The text changed since — this proposal is closed")
        await waitUntil { runner.invocations.filter { $0.contains("proposals") }.count > before }
    }

    func testDoublePressRunsOnce() async {
        let runner = ScriptedCoachRunner(Self.standard())
        runner.hold()
        let center = makeCenter(runner)
        let first = Task { await center.decline(7) }
        await waitUntil { center.pending.contains(7) }
        await center.decline(7)
        XCTAssertEqual(runner.invocations.filter { $0.contains("decline") }.count, 1)
        runner.release(0)
        await first.value
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testRunNowBusyLine() async {
        let runner = ScriptedCoachRunner { _ in
            throw Self.failure(#"{"ok":false,"error":"the coach is already running","code":"busy"}"#)
        }
        let center = makeCenter(runner)
        await center.runNow()
        XCTAssertEqual(center.runLine, "The coach is already running — the section updates when it finishes")
        XCTAssertFalse(center.running)
    }

    func testRunNowJudgeErrorLine() async {
        let runner = ScriptedCoachRunner { args in
            args.dropFirst().first == "run" ? Data(#"{"ok":true,"judge_error":"boom"}"#.utf8) : try Self.standard()(args)
        }
        let center = makeCenter(runner)
        await center.runNow()
        XCTAssertEqual(center.runLine, "Verdicts could not be updated: boom")
    }

    func testRunNowDisabledWhileRunning() async {
        let runner = ScriptedCoachRunner(Self.standard())
        runner.hold()
        let center = makeCenter(runner)
        let first = Task { await center.runNow() }
        await waitUntil { center.running }
        await center.runNow()
        XCTAssertEqual(runner.invocations.filter { $0.contains("run") }.count, 1)
        runner.release(0)
        await first.value
        XCTAssertFalse(center.running)
    }

    func testRunNowFailureLine() async {
        let runner = ScriptedCoachRunner { args in
            if args.dropFirst().first == "run" { throw Self.failure(#"{"ok":false,"error":"no provider","code":"failed"}"#) }
            return try Self.standard()(args)
        }
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await waitUntil { center.proposals?.value != nil }
        let before = center.proposals
        await center.runNow()
        XCTAssertEqual(center.runLine, "The coach run failed: no provider")
        XCTAssertEqual(center.proposals, before)
        XCTAssertFalse(center.running)
    }

    func testRunNowTimeoutLine() async {
        let runner = ScriptedCoachRunner { _ in throw CLIRunnerError.nonZeroExit(code: -1, stderr: "") }
        let center = makeCenter(runner)
        await center.runNow()
        XCTAssertEqual(center.runLine, "The coach run failed: timed out")
        XCTAssertFalse(center.running)
    }

    func testStopDoesNotCancelRun() async {
        let runner = ScriptedCoachRunner(Self.standard())
        runner.hold()
        let center = makeCenter(runner)
        let call = Task { await center.runNow() }
        await waitUntil { runner.invocations.count == 1 }
        center.stop()
        runner.release(0)
        await call.value
        XCTAssertEqual(runner.cancellations, [false], "stop() leaves the CLI call uncancelled")
        XCTAssertNil(center.runLine)
    }

    func testEditedAcceptSendsStdin() async {
        let runner = ScriptedCoachRunner(Self.standard())
        let center = makeCenter(runner)
        await center.accept(5, editedText: "new text")
        XCTAssertEqual(runner.invocations.first, ["coach", "accept", "5", "--json", "--stdin"])
        XCTAssertEqual(runner.stdinTexts, ["new text"])
    }

    func testRollbackChangedSinceReturnsDiff() async {
        let runner = ScriptedCoachRunner { _ in
            throw Self.failure(#"{"ok":false,"error":"changed","code":"changed_since","diff":"-a\n+b"}"#)
        }
        let center = makeCenter(runner)
        let diff = await center.rollback(5, force: false)
        XCTAssertEqual(diff, "-a\n+b")
        XCTAssertNil(center.cardErrors[5])
    }

    func testStoredAllPeriodReadsAsWeek() {
        XCTAssertEqual(AgentAnalyticsCenter.Period.stored(0), .week)
        XCTAssertEqual(AgentAnalyticsCenter.Period.stored(1), .day)
        XCTAssertEqual(AgentAnalyticsCenter.Period.stored(30), .month)
    }
}
