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
    private var suites: [String] = []

    override func tearDown() {
        centers.forEach { $0.stop() }
        suites.forEach { UserDefaults().removePersistentDomain(forName: $0) }
        super.tearDown()
    }

    private func makeCenter(_ runner: ScriptedCoachRunner, defaults: UserDefaults? = nil) -> CoachCenter {
        let center = CoachCenter(runner: runner, interval: .seconds(3600), defaults: defaults ?? makeDefaults())
        centers.append(center)
        return center
    }

    /// A private defaults domain: `coach.linkFailed` never reaches the real one.
    private func makeDefaults() -> UserDefaults {
        let name = "CoachCenterTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name) ?? .standard
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
        await waitUntil { runner.invocations.filter { $0.dropFirst().first == "status" }.count == 2 }
        let last = runner.invocations.last { $0.dropFirst().first == "status" }
        XCTAssertEqual(last, ["coach", "status", "--workbench", "3", "--days", "7", "--json"])
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

    // MARK: - Accept through a session (context actions, spec C6)

    /// One open (or `status`) context repository proposal, id 50, workbench 3.
    nonisolated private static func contextProposals(status: String = "open", extra: String = "") -> Data {
        Data("""
        {"ok":true,"proposals":[{"id":50,"title":"Slim CLAUDE.md","why":"w","destination":"repo_claude_md",\
        "workbench_id":3,"prompt_id":"","kind":"restructure","metric":"start_tokens","before":"","after":"",\
        "evidence":[],"sources":6,"status":"\(status)","created_at":"2026-11-01T09:00:00Z","decided_at":null,\
        "baseline":null,"verdict":"","verdict_value":null,"verdict_at":null,"reverts_id":0,"budget":0,\
        "origin":"context","source_key":""\(extra)}]}
        """.utf8)
    }

    nonisolated private static let brief = Data(#"{"ok":true,"id":50,"title":"Slim CLAUDE.md","prompt":"Move the sections."}"#.utf8)

    /// brief / accept / proposals answered; `accept` by `onAccept` (call index from 0).
    nonisolated private static func sessionScript(
        status: String = "open",
        extra: String = "",
        onAccept: @escaping @Sendable (Int) throws -> Data = { _ in Data(#"{"ok":true}"#.utf8) }
    ) -> @Sendable ([String]) throws -> Data {
        let accepts = Counter()
        return { args in
            switch args.dropFirst().first {
            case "brief": return brief
            case "proposals": return contextProposals(status: status, extra: extra)
            case "accept": return try onAccept(accepts.next())
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
    }

    /// The CLI calls apart from the reads.
    private func verbs(_ runner: ScriptedCoachRunner) -> [[String]] {
        runner.invocations.filter { !["proposals", "status"].contains($0.dropFirst().first ?? "") }
    }

    func testAcceptThroughSessionStartsThenAccepts() async {
        let runner = ScriptedCoachRunner(Self.sessionScript())
        let center = makeCenter(runner)
        var started: [(String, String, Int)] = []
        await center.acceptThroughSession(50) { title, prompt in
            started.append((title, prompt, self.verbs(runner).count))
            return 41
        }
        XCTAssertEqual(verbs(runner), [["coach", "brief", "50", "--json"],
                                       ["coach", "accept", "50", "--session", "41", "--json"]])
        XCTAssertEqual(started.map(\.0), ["Slim CLAUDE.md"])
        XCTAssertEqual(started.map(\.1), ["Move the sections."])
        XCTAssertEqual(started.first?.2, 1, "the session starts after the brief and before the accept")
        XCTAssertNil(center.cardErrors[50])
        XCTAssertTrue(center.linkFailed.isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
        XCTAssertTrue(runner.invocations.contains(["coach", "proposals", "--status", "all", "--json"]),
                      "the list is read again before the press is released")
    }

    func testAcceptThroughSessionStartFailureLeavesOpen() async {
        let runner = ScriptedCoachRunner(Self.sessionScript())
        let center = makeCenter(runner)
        await center.acceptThroughSession(50) { _, _ in nil }
        XCTAssertEqual(verbs(runner), [["coach", "brief", "50", "--json"]], "no coach accept without a session")
        XCTAssertEqual(center.cardErrors[50], CoachCenter.sessionNotStarted)
        XCTAssertTrue(center.linkFailed.isEmpty)
        XCTAssertTrue(center.starting(live: []).isEmpty)
        XCTAssertTrue(center.pending.isEmpty)
    }

    func testAcceptThroughSessionBriefFailureStartsNothing() async {
        let runner = ScriptedCoachRunner { args in
            if args.dropFirst().first == "brief" {
                throw Self.failure(#"{"ok":false,"error":"no such proposal","code":"not_found"}"#)
            }
            return Data(#"{"ok":true}"#.utf8)
        }
        let center = makeCenter(runner)
        var starts = 0
        await center.acceptThroughSession(50) { _, _ in
            starts += 1
            return 41
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(center.cardErrors[50], "no such proposal")
    }

    func testDoublePressIgnored() async {
        let runner = ScriptedCoachRunner(Self.sessionScript())
        let center = makeCenter(runner)
        let gate = AsyncGate()
        var starts = 0
        let start: (String, String) async -> Int64? = { _, _ in
            starts += 1
            await gate.wait()
            return 41
        }
        let first = Task { await center.acceptThroughSession(50, start: start) }
        await waitUntil { starts == 1 }
        XCTAssertTrue(center.pending.contains(50))
        XCTAssertTrue(center.starting(live: []).contains(50), "the row is starting from the press")
        await center.acceptThroughSession(50, start: start)
        await center.accept(50, editedText: nil)
        XCTAssertEqual(verbs(runner), [["coach", "brief", "50", "--json"]], "the second press ran nothing")
        gate.release()
        await first.value
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(verbs(runner).filter { $0.contains("brief") }.count, 1)
    }

    func testStartBeganThenNavigatedAway() async {
        let runner = ScriptedCoachRunner(Self.sessionScript())
        let center = makeCenter(runner)
        center.show(workbench: 3, period: .week)
        let gate = AsyncGate()
        let flow = Task {
            await center.acceptThroughSession(50) { _, _ in
                await gate.wait()
                return 41
            }
        }
        await waitUntil { self.verbs(runner).count == 1 }
        // The owner leaves the Analytics pane while the session starts.
        center.hide(workbench: 3)
        XCTAssertTrue(center.pending.contains(50))
        XCTAssertTrue(center.starting(live: []).contains(50))
        gate.release()
        await flow.value
        XCTAssertEqual(verbs(runner).last, ["coach", "accept", "50", "--session", "41", "--json"],
                       "the accept is recorded after the pane went away")
        XCTAssertTrue(center.starting(live: []).contains(50), "not live yet: still starting")
        XCTAssertFalse(center.starting(live: [41]).contains(50), "live: working")
        XCTAssertFalse(center.starting(live: [], now: Date().addingTimeInterval(CoachCenter.launchGrace + 1))
            .contains(50), "a session that never went live stops counting as starting")
    }

    func testAcceptFailsAfterStartRecordsLinkFailed() async {
        let runner = ScriptedCoachRunner(Self.sessionScript { _ in
            throw Self.failure(#"{"ok":false,"error":"database is locked","code":"io"}"#)
        })
        let center = makeCenter(runner)
        var starts = 0
        let start: (String, String) async -> Int64? = { _, _ in
            starts += 1
            return 41
        }
        await center.acceptThroughSession(50, start: start)
        XCTAssertEqual(verbs(runner).filter { $0.contains("accept") }.count, 2, "one retry")
        XCTAssertEqual(center.linkFailed, [50: 41])
        XCTAssertEqual(center.cardErrors[50], "database is locked", "the last link error stays on the card")
        // A later press starts no second session.
        await center.acceptThroughSession(50, start: start)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(verbs(runner).filter { $0.contains("brief") }.count, 1)
        // Retry Link records the same session.
        runner.answer(Self.sessionScript())
        await center.retryLink(50)
        XCTAssertEqual(verbs(runner).last, ["coach", "accept", "50", "--session", "41", "--json"])
        XCTAssertTrue(center.linkFailed.isEmpty)
    }

    func testRetryLinkFailureKeepsTheLink() async {
        let runner = ScriptedCoachRunner(Self.sessionScript { _ in
            throw Self.failure(#"{"ok":false,"error":"database is locked","code":"io"}"#)
        })
        let center = makeCenter(runner)
        await center.acceptThroughSession(50) { _, _ in 41 }
        await center.retryLink(50)
        XCTAssertEqual(center.linkFailed, [50: 41])
        XCTAssertEqual(center.cardErrors[50], "database is locked")
    }

    func testAcceptFailsAfterStartStateChangedIsQuiet() async {
        let runner = ScriptedCoachRunner(Self.sessionScript { call in
            if call == 0 { throw Self.failure(#"{"ok":false,"error":"timed out","code":"io"}"#) }
            throw Self.failure(#"{"ok":false,"error":"already accepted","code":"state_changed"}"#)
        })
        let center = makeCenter(runner)
        await center.acceptThroughSession(50) { _, _ in 41 }
        XCTAssertEqual(verbs(runner).filter { $0.contains("accept") }.count, 2)
        XCTAssertTrue(center.linkFailed.isEmpty)
        XCTAssertNil(center.cardErrors[50])
        XCTAssertTrue(runner.invocations.contains(["coach", "proposals", "--status", "all", "--json"]))
    }

    func testDismissSessionGoneCallsDismiss() async {
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted"))
        let center = makeCenter(runner)
        await center.dismiss(50)
        XCTAssertEqual(verbs(runner), [["coach", "dismiss", "50", "--json"]])
        XCTAssertNil(center.cardErrors[50])
    }

    func testStartAgainUsesRestart() async {
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted"))
        let center = makeCenter(runner)
        await center.restartThroughSession(50) { _, _ in 42 }
        XCTAssertEqual(verbs(runner), [["coach", "brief", "50", "--json"],
                                       ["coach", "accept", "50", "--session", "42", "--restart", "--json"]])
        XCTAssertTrue(center.starting(live: []).contains(50), "starting until session 42 is live")
    }

    func testReapplyAndRevertArgv() async {
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted"))
        let center = makeCenter(runner)
        await center.reapply(50)
        var started: [String] = []
        await center.revertThroughSession(50) { title, _ in
            started.append(title)
            return 43
        }
        XCTAssertEqual(verbs(runner), [["coach", "reapply", "50", "--json"],
                                       ["coach", "brief", "50", "--revert", "--json"]])
        XCTAssertEqual(started, ["Slim CLAUDE.md"], "a revert records nothing: its PR is the record")
    }

    /// A Turn Off Again that finds the setting no longer on (or changed
    /// meanwhile) gets its own line, never "this proposal is closed": the
    /// row is still accepted. A state_changed is quiet (done elsewhere).
    func testReapplyStaleHasItsOwnLine() async {
        let base = Self.sessionScript(status: "accepted")
        let code = Counter()
        let runner = ScriptedCoachRunner { args in
            guard args.dropFirst().first == "reapply" else { return try base(args) }
            if code.next() == 0 {
                throw Self.failure(#"{"ok":false,"error":"the setting changed since it was read","code":"stale"}"#)
            }
            throw Self.failure(#"{"ok":false,"error":"not reverted","code":"state_changed"}"#)
        }
        let center = makeCenter(runner)
        await center.reapply(50)
        XCTAssertEqual(center.cardErrors[50], CoachCenter.reapplyStale)
        XCTAssertNotEqual(center.cardErrors[50], "The text changed since — this proposal is closed")
        await center.reapply(50)
        XCTAssertNil(center.cardErrors[50], "state_changed: quiet, the list shows the change")
    }

    /// On a Start Again (`--restart`), state_changed means the row was not
    /// moved to the new session: a link failure with its reason, never a
    /// quiet success that leaves the session unlinked.
    func testRestartStateChangedIsALinkFailure() async {
        let ended = #","session_id":41,"via_session":true,"session_branch":"wt/a""#
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: ended) { _ in
            throw Self.failure(#"{"ok":false,"error":"coach proposal state changed","code":"state_changed"}"#)
        })
        let center = makeCenter(runner)
        await center.restartThroughSession(50) { _, _ in 42 }
        XCTAssertEqual(verbs(runner).filter { $0.contains("--restart") }.count, 1, "no retry of a refusal")
        XCTAssertEqual(center.linkFailed, [50: 42])
        XCTAssertEqual(center.restartLinks, [50])
        XCTAssertEqual(center.cardErrors[50], "coach proposal state changed")
    }

    func testLinkFailedSurvivesRestart() async throws {
        let defaults = makeDefaults()
        let runner = ScriptedCoachRunner(Self.sessionScript { _ in
            throw Self.failure(#"{"ok":false,"error":"database is locked","code":"io"}"#)
        })
        await makeCenter(runner, defaults: defaults).acceptThroughSession(50) { _, _ in 41 }
        // The app restarts: a new center over the same defaults.
        let again = makeCenter(ScriptedCoachRunner(Self.sessionScript()), defaults: defaults)
        XCTAssertEqual(again.linkFailed, [50: 41])
        let list = try JSONDecoder().decode(CoachProposalList.self, from: Self.contextProposals())
        let row = try XCTUnwrap(ContextActionsPresentation.rows(
            proposals: list.proposals, workbenchID: 3, sources: [], sessionKinds: [41: .running],
            linkFailed: again.linkFailed, now: Date()
        ).doThese.first)
        XCTAssertFalse(row.actions.contains(.accept), "Accept stays hidden after a restart")
        XCTAssertEqual(row.actions, [.openSession, .retryLink])
    }

    func testLinkFailedDroppedWhenProposalNotOpen() async {
        let defaults = makeDefaults()
        defaults.set(["50": NSNumber(value: 41)], forKey: CoachCenter.linkFailedKey)
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted"))
        let center = makeCenter(runner, defaults: defaults)
        XCTAssertEqual(center.linkFailed, [50: 41])
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        XCTAssertTrue(center.linkFailed.isEmpty)
        XCTAssertNil(defaults.dictionary(forKey: CoachCenter.linkFailedKey)?["50"])
    }

    func testLinkKeptWhileProposalOpenAndDroppedWhenSessionGone() async {
        let defaults = makeDefaults()
        defaults.set(["50": NSNumber(value: 41)], forKey: CoachCenter.linkFailedKey)
        let center = makeCenter(ScriptedCoachRunner(Self.sessionScript()), defaults: defaults)
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        XCTAssertEqual(center.linkFailed, [50: 41], "still open: kept")
        center.forgetLink(50, session: 99)
        XCTAssertEqual(center.linkFailed, [50: 41], "another session's removal does not drop it")
        center.forgetLink(50, session: 41)
        XCTAssertTrue(center.linkFailed.isEmpty)
        XCTAssertTrue(makeCenter(ScriptedCoachRunner(Self.sessionScript()), defaults: defaults).linkFailed.isEmpty)
    }

    // MARK: - Fix round 1: no second session from Revert… or Start Again

    nonisolated private static let ioFailure = #"{"ok":false,"error":"database is locked","code":"io"}"#
    nonisolated private static let merged = #","session_id":41,"via_session":true,"session_branch":"wt/a","pr":12,"pr_state":"merged""#

    func testDoubleRevertPressStartsOnce() async {
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: Self.merged))
        let center = makeCenter(runner)
        var starts = 0
        let start: (String, String) async -> Int64? = { _, _ in
            starts += 1
            return 43
        }
        await center.revertThroughSession(50, start: start)
        await center.revertThroughSession(50, start: start)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(center.revertSessions, [50: 43])
        XCTAssertEqual(verbs(runner).filter { $0.contains("brief") }.count, 1)
    }

    func testRevertSessionSurvivesRestartAndGoesWithTheStatus() async throws {
        let defaults = makeDefaults()
        let first = makeCenter(ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: Self.merged)),
                               defaults: defaults)
        await first.revertThroughSession(50) { _, _ in 43 }
        let again = makeCenter(ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: Self.merged)),
                               defaults: defaults)
        XCTAssertEqual(again.revertSessions, [50: 43], "the revert session survives a restart")
        var starts = 0
        await again.revertThroughSession(50) { _, _ in
            starts += 1
            return 44
        }
        XCTAssertEqual(starts, 0)
        let list = try JSONDecoder().decode(CoachProposalList.self,
                                            from: Self.contextProposals(status: "accepted", extra: Self.merged))
        let row = try XCTUnwrap(ContextActionsPresentation.row(
            of: list.proposals[0], sessionKinds: [43: .working], linkFailed: [:], revertSessions: again.revertSessions))
        XCTAssertEqual(row.state, .reverting(43))
        XCTAssertEqual(row.actions, [.openSession], "no second Revert…")
        // Rolled back: the entry goes.
        let rolled = makeCenter(ScriptedCoachRunner(Self.sessionScript(status: "rolled_back")), defaults: defaults)
        rolled.refreshProposals()
        await waitUntil { rolled.proposals?.value != nil }
        XCTAssertTrue(rolled.revertSessions.isEmpty)
        rolled.forgetRevert(50, session: 43)
    }

    func testRevertSessionGoneDropsTheEntry() async {
        let center = makeCenter(ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: Self.merged)))
        await center.revertThroughSession(50) { _, _ in 43 }
        center.forgetRevert(50, session: 99)
        XCTAssertEqual(center.revertSessions, [50: 43])
        center.forgetRevert(50, session: 43)
        XCTAssertTrue(center.revertSessions.isEmpty)
    }

    func testRestartLinkFailureOffersRetryLinkNeverStartAgain() async throws {
        let ended = #","session_id":41,"via_session":true,"session_branch":"wt/a""#
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: ended) { _ in
            throw Self.failure(Self.ioFailure)
        })
        let center = makeCenter(runner)
        var starts = 0
        let start: (String, String) async -> Int64? = { _, _ in
            starts += 1
            return 42
        }
        await center.restartThroughSession(50, start: start)
        XCTAssertEqual(verbs(runner).filter { $0.contains("--restart") }.count, 2, "one retry")
        XCTAssertEqual(center.linkFailed, [50: 42])
        XCTAssertEqual(center.restartLinks, [50])
        // Past the 60 s window the row still offers Retry Link, not Start Again.
        let later = Date().addingTimeInterval(CoachCenter.launchGrace + 60)
        XCTAssertFalse(center.starting(live: [], now: later).contains(50))
        let list = try JSONDecoder().decode(CoachProposalList.self,
                                            from: Self.contextProposals(status: "accepted", extra: ended))
        let row = try XCTUnwrap(ContextActionsPresentation.rows(
            proposals: list.proposals, workbenchID: 3, sources: [], sessionKinds: [41: .stopped, 42: .notStarted],
            linkFailed: center.linkFailed, now: later, starting: center.starting(live: [], now: later)
        ).doThese.first)
        XCTAssertEqual(row.actions, [.openSession, .retryLink])
        await center.restartThroughSession(50, start: start)
        XCTAssertEqual(starts, 1, "no second session")
        // The list still names session 41: the entry stays; Retry Link sends --restart.
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        XCTAssertEqual(center.linkFailed, [50: 42])
        runner.answer(Self.sessionScript(status: "accepted", extra: #","session_id":42,"via_session":true"#))
        await center.retryLink(50)
        XCTAssertEqual(verbs(runner).last, ["coach", "accept", "50", "--session", "42", "--restart", "--json"])
        XCTAssertTrue(center.linkFailed.isEmpty)
        XCTAssertTrue(center.restartLinks.isEmpty)
    }

    func testRestartLinkDroppedOnceTheRowNamesTheSession() async {
        let defaults = makeDefaults()
        defaults.set(["50": NSNumber(value: 42)], forKey: CoachCenter.linkFailedKey)
        defaults.set([NSNumber(value: 50)], forKey: CoachCenter.restartLinksKey)
        let runner = ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: #","session_id":42,"via_session":true"#))
        let center = makeCenter(runner, defaults: defaults)
        XCTAssertEqual(center.restartLinks, [50], "survives a restart")
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        XCTAssertTrue(center.linkFailed.isEmpty)
    }

    func testAcceptAfterALaunchSaysSo() async {
        let runner = ScriptedCoachRunner(Self.sessionScript())
        let center = makeCenter(runner)
        await center.acceptThroughSession(50) { _, _ in 41 }
        // The list read after the link still said open (as if it failed).
        await center.acceptThroughSession(50) { _, _ in 99 }
        XCTAssertEqual(center.cardErrors[50], CoachCenter.alreadyStarted)
        XCTAssertEqual(verbs(runner).filter { $0.contains("brief") }.count, 1)
    }

    // MARK: - Fix round 2

    func testRevertAgainAfterTheRevertSessionEnded() async throws {
        let center = makeCenter(ScriptedCoachRunner(Self.sessionScript(status: "accepted", extra: Self.merged)))
        await center.revertThroughSession(50) { _, _ in 43 }
        let list = try JSONDecoder().decode(CoachProposalList.self,
                                            from: Self.contextProposals(status: "accepted", extra: Self.merged))
        let row = try XCTUnwrap(ContextActionsPresentation.row(
            of: list.proposals[0], sessionKinds: [43: .stopped], linkFailed: [:], revertSessions: center.revertSessions))
        XCTAssertEqual(row.state, .revertEnded(43))
        var starts: [Int64] = []
        let inputs = ContextActionsInputs(
            coach: center, workbench: 3, sessionKinds: [43: .stopped], liveSessions: [], repository: nil,
            startSession: { workbench, _, _ in
                starts.append(workbench)
                return 44
            }, openSession: { _ in }
        )
        inputs.perform(.revert, row, openURL: { _ in }, rollback: { _ in })
        await waitUntil { center.revertSessions[50] == 44 }
        XCTAssertEqual(starts, [3], "the ended entry went and one new revert session started")
    }
}

/// A thread-safe call counter for scripted answers.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
