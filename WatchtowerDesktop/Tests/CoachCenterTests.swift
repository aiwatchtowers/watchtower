import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Answers `coach` calls from a script, optionally holding calls open.
private final class ScriptedCoachRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var stdins: [String] = []
    private var gates: [AsyncGate] = []
    private var holding = false
    private var cancelledAtReturn: [Bool] = []
    private var script: @Sendable ([String]) throws -> Data
    private var callWaiters: [(met: ([[String]]) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ script: @escaping @Sendable ([String]) throws -> Data) { self.script = script }

    var invocations: [[String]] { lock.withLock { calls } }
    var stdinTexts: [String] { lock.withLock { stdins } }
    var cancellations: [Bool] { lock.withLock { cancelledAtReturn } }

    func hold() { lock.withLock { holding = true } }
    func answer(_ next: @escaping @Sendable ([String]) throws -> Data) { lock.withLock { script = next } }
    func release(_ index: Int) { lock.withLock { gates[index] }.release() }

    /// Returns once the calls so far satisfy `met` (re-checked on every call).
    func untilCalls(_ met: @escaping ([[String]]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if met(calls) { return true }
                callWaiters.append((met, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    func run(args: [String]) async throws -> Data { try await record(args, stdin: nil) }
    func run(args: [String], stdin: Data) async throws -> Data {
        try await record(args, stdin: String(bytes: stdin, encoding: .utf8) ?? "")
    }

    private func record(_ args: [String], stdin: String?) async throws -> Data {
        let gate = AsyncGate()
        let (held, ready) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            calls.append(args)
            if let stdin { stdins.append(stdin) }
            gates.append(gate)
            let ready = callWaiters.filter { $0.met(calls) }.map(\.continuation)
            callWaiters.removeAll { $0.met(calls) }
            return (holding, ready)
        }
        ready.forEach { $0.resume() }
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

    /// Waits until `condition` holds, re-checking on every change of the
    /// center's observable state it reads — no deadline.
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        await untilObserved(condition)
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

    func testRefreshProposalsAsksTheCLI() async {
        let runner = ScriptedCoachRunner(Self.standard())
        let center = makeCenter(runner)
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        XCTAssertEqual(runner.invocations, [["coach", "proposals", "--status", "all", "--json"]])
        XCTAssertEqual(center.proposals?.value?.map(\.id), [7, 5])
    }

    /// The tiles follow the pane's agent filter (#1517, spec §4.7).
    func testStatusFollowsAgentFilter() async {
        let runner = ScriptedCoachRunner(Self.standard())
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week, agent: .kind(.codex))
        await waitUntil { center.status[3]?.value != nil }
        XCTAssertTrue(runner.invocations.contains(
            ["coach", "status", "--workbench", "3", "--days", "7", "--agent", "codex", "--json"]), "\(runner.invocations)")

        center.show(workbench: 3, period: .week, agent: .all)
        await runner.untilCalls { $0.filter { $0.dropFirst().first == "status" }.count == 2 }
        let last = runner.invocations.last { $0.dropFirst().first == "status" }
        XCTAssertEqual(last, ["coach", "status", "--workbench", "3", "--days", "7", "--json"])
    }

    func testPeriodChangeDropsStaleStatus() async {
        let runner = ScriptedCoachRunner(Self.standard())
        runner.hold()
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        await runner.untilCalls { $0.count == 2 }
        center.show(workbench: 3, period: .day)
        // Release the 7-day status (the first call) after the switch.
        guard let index = runner.invocations.firstIndex(where: { $0.contains("status") }) else { return XCTFail("no status call") }
        runner.release(index)
        // The 7-day call's run ended (its reply handled) once the queued
        // 1-day status starts.
        let oneDay = { (calls: [[String]]) in calls.contains { $0.contains("status") && $0.contains("1") } }
        await runner.untilCalls(oneDay)
        XCTAssertNil(center.status[3]?.value, "a 7-day reply after a switch to 1 day is not stored")
        for i in 0..<runner.invocations.count where i != index {
            if i < runner.invocations.count { runner.release(i) }
        }
        await waitUntil { center.status[3]?.value != nil }  // the 1-day reply is stored
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
        await runner.untilCalls { $0.filter { $0.contains("proposals") }.count > before }
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
        await runner.untilCalls { $0.count == 1 }
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

    func testForcedRollbackStillRefusedShowsTheLine() async {
        let runner = ScriptedCoachRunner { _ in
            throw Self.failure(#"{"ok":false,"error":"CLAUDE.md changed since Accept","code":"changed_since","diff":"+x"}"#)
        }
        let center = makeCenter(runner)
        let diff = await center.rollback(9, force: true)
        XCTAssertNil(diff)
        XCTAssertEqual(center.cardErrors[9], "CLAUDE.md changed since Accept", "the sheet stays open with the reason")
    }

    func testDirtyBeforeTheListLoadedShowsTheCLILine() async {
        let runner = ScriptedCoachRunner { _ in throw Self.failure(Self.dirtyFailure) }
        let center = makeCenter(runner)
        await center.accept(9, editedText: nil)
        XCTAssertEqual(center.cardErrors[9], try? XCTUnwrap(CoachFailure.parse(stderr: Self.dirtyFailure)).error)
    }

    /// A repository proposal (#9, the workbench's CLAUDE.md) in the list.
    nonisolated private static let repoList = #"{"ok":true,"proposals":[{"id":9,"title":"Tests","why":"w","#
        + #""destination":"repo_claude_md","workbench_id":3,"prompt_id":"","kind":"add","metric":"corrections","#
        + #""before":"","after":"x","evidence":[],"sources":1,"status":"open","created_at":"2026-11-01T09:00:00Z","#
        + #""decided_at":null,"verdict":"","reverts_id":0,"budget":0,"folder_branch":"main"}]}"#

    /// The failure objects `coach accept --json` prints for the two git
    /// refusals (`cmd/coach.go` `codedCoachErr`, the Applier's wrap around
    /// `coach.RepoDirtyLine` / `coach.RepoNotGitLine`).
    nonisolated private static let dirtyFailure = #"{"ok":false,"error":"coach proposal 9 (repo_claude_md): "#
        + #"CLAUDE.md has uncommitted changes — commit or discard them, then press Accept again.","code":"dirty"}"#
    nonisolated private static let notGitFailure = #"{"ok":false,"error":"coach proposal 9 (repo_claude_md): "#
        + #"This workbench folder is not a git repository: Watchtower changes files here only where you can review "#
        + #"and commit the change.","code":"not_git"}"#

    func testRepoAcceptCodes() async throws {
        let runner = ScriptedCoachRunner { args in
            switch args.dropFirst().first {
            case "proposals": return Data(Self.repoList.utf8)
            case "accept": throw Self.failure(Self.dirtyFailure)
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
        let center = makeCenter(runner)
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }

        await center.accept(9, editedText: nil)
        XCTAssertEqual(center.cardErrors[9], TuningChatTexts.repoDirty(path: "CLAUDE.md"))
        let dirtyCLI = try XCTUnwrap(CoachFailure.parse(stderr: Self.dirtyFailure)).error
        XCTAssertTrue(dirtyCLI.hasSuffix(try XCTUnwrap(center.cardErrors[9])), "the Go text, without its id prefix")

        runner.answer { args in
            if args.dropFirst().first == "accept" { throw Self.failure(Self.notGitFailure) }
            return Data(Self.repoList.utf8)
        }
        await center.accept(9, editedText: nil)
        XCTAssertEqual(center.cardErrors[9], TuningChatTexts.repoNotGit)
        XCTAssertTrue(try XCTUnwrap(CoachFailure.parse(stderr: Self.notGitFailure)).error.hasSuffix(TuningChatTexts.repoNotGit))
        XCTAssertNil(center.written[9])

        runner.answer { args in
            if args.dropFirst().first == "accept" {
                return Data(#"{"ok":true,"id":9,"status":"accepted","written_path":"CLAUDE.md","written_branch":"main"}"#.utf8)
            }
            return Data(Self.repoList.utf8)
        }
        await center.accept(9, editedText: nil)
        XCTAssertNil(center.cardErrors[9])
        XCTAssertEqual(center.written[9], CoachWrittenFile(path: "CLAUDE.md", branch: "main"))
    }
}
