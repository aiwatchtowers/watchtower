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
        // `pending` is set before the CLI call is recorded (the runner hops off
        // the main actor): wait for the held call itself, not the flag.
        await runner.untilCalls { $0.contains { $0.contains("decline") } }
        XCTAssertTrue(center.pending.contains(7))
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
        // `running` is set before the CLI call is recorded (it runs in its own
        // task): wait for the held call itself, not the flag.
        await runner.untilCalls { $0.contains { $0.contains("run") } }
        XCTAssertTrue(center.running)
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

    // MARK: - Pull-request edits (spec 2026-11-19 §4.4–§4.6)

    /// #9 as an open repository proposal, #10 as an accepted PR edit.
    nonisolated private static let prList = #"{"ok":true,"proposals":[{"id":9,"title":"Tests","why":"w","#
        + #""destination":"repo_claude_md","workbench_id":3,"prompt_id":"","kind":"add","metric":"corrections","#
        + #""before":"","after":"x","evidence":[],"sources":1,"status":"open","created_at":"2026-11-01T09:00:00Z","#
        + #""decided_at":null,"verdict":"","reverts_id":0,"budget":0,"folder_branch":"main"},"#
        + #"{"id":10,"title":"Fixtures","why":"w","destination":"repo_claude_md","workbench_id":3,"prompt_id":"","#
        + #""kind":"add","metric":"corrections","before":"","after":"y","evidence":[],"sources":1,"#
        + #""status":"accepted","created_at":"2026-11-01T09:00:00Z","decided_at":"2026-11-02T09:00:00Z","#
        + #""verdict":"","reverts_id":0,"budget":0,"written_branch":"coach/a1b2c3d4/proposal-10","#
        + #""pr_url":"https://github.com/acme/repo/pull/12","revert_pr_url":""}]}"#

    /// A failure object as `coach accept|rollback --json` prints it: the
    /// Applier's id prefix, Go's sentence, the seam's words.
    nonisolated private static func prFailure(_ id: Int, _ code: String, _ sentence: String, _ words: String) -> Error {
        let error = "coach proposal \(id) (repo_claude_md): \(sentence) (\(words))"
        let data = try? JSONSerialization.data(withJSONObject: ["ok": false, "error": error, "code": code])
        return failure(String(bytes: data ?? Data(), encoding: .utf8) ?? "")
    }

    func testPRAcceptRefusalsNameTheCardAndOfferRetry() async throws {
        struct Case {
            let code: String, sentence: String, words: String, line: String, retry: Bool
            init(_ code: String, _ sentence: String, _ words: String, _ line: String, _ retry: Bool) {
                (self.code, self.sentence, self.words, self.line, self.retry) = (code, sentence, words, line, retry)
            }
        }
        let cases: [Case] = [
            Case("no_gh", CoachPRTexts.noGH, "gh: not logged in", CoachPRTexts.noGH, false),
            Case("base_differs", CoachPRTexts.baseDiffers(path: "CLAUDE.md"), "CLAUDE.md on main",
                 CoachPRTexts.baseDiffers(path: "CLAUDE.md"), false),
            Case("push_failed", CoachPRTexts.pushFailed, "remote: Permission to acme/repo.git denied",
                 CoachPRTexts.pushFailed + " (remote: Permission to acme/repo.git denied)", true),
            Case("pr_failed", CoachPRTexts.prFailed, "gh: HTTP 502", CoachPRTexts.prFailed + " (gh: HTTP 502)", true),
            Case("timeout", CoachPRTexts.timeout, "context deadline exceeded", CoachPRTexts.timeout, true),
            Case("github_unreachable", CoachPRTexts.unreachable, "gh auth status: error connecting to api.github.com",
                 CoachPRTexts.unreachable, true),
            Case("in_progress", CoachPRTexts.inProgress, "coach.ErrInProgress", CoachPRTexts.inProgress, false)
        ]
        for c in cases {
            let runner = ScriptedCoachRunner { args in
                switch args.dropFirst().first {
                case "proposals": return Data(Self.prList.utf8)
                case "accept": throw Self.prFailure(9, c.code, c.sentence, c.words)
                default: return Data(#"{"ok":true}"#.utf8)
                }
            }
            let center = makeCenter(runner)
            center.refreshProposals()
            await waitUntil { center.proposals?.value != nil }
            await center.accept(9, editedText: "edited")
            XCTAssertEqual(center.cardErrors[9], c.line, c.code)
            XCTAssertEqual(center.retries[9], c.retry ? .accept(editedText: "edited") : nil, c.code)
        }
    }

    func testRetryRunsTheSameAcceptAndClearsOnSuccess() async {
        let runner = ScriptedCoachRunner { args in
            switch args.dropFirst().first {
            case "proposals": return Data(Self.prList.utf8)
            case "accept": throw Self.prFailure(9, "timeout", CoachPRTexts.timeout, "deadline")
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
        let center = makeCenter(runner)
        await center.accept(9, editedText: nil)
        XCTAssertEqual(center.retries[9], .accept(editedText: nil))
        runner.answer { args in
            if args.dropFirst().first == "accept" {
                let ok = #"{"ok":true,"id":9,"status":"accepted","written_path":"CLAUDE.md","#
                    + #""written_branch":"coach/a1b2c3d4/proposal-9","pr_url":"https://github.com/acme/repo/pull/12"}"#
                return Data(ok.utf8)
            }
            return Data(Self.prList.utf8)
        }
        await center.accept(9, editedText: nil)
        XCTAssertNil(center.cardErrors[9])
        XCTAssertNil(center.retries[9])
        XCTAssertEqual(center.written[9]?.prURL, "https://github.com/acme/repo/pull/12")
    }

    /// Finding 1: a merged PR whose file moved on the default branch comes
    /// back `changed_since` with the diff. The center hands the diff to the
    /// sheet (no card error, no Retry), and the sheet for a PR edit offers no
    /// Roll Back Anyway — `--force` cannot revert a pull request — so the
    /// owner is never led into a rollback that fails forever.
    func testPRRollbackChangedSinceOpensTheSheetWithoutForce() async throws {
        let runner = ScriptedCoachRunner { args in
            switch args.dropFirst().first {
            case "proposals": return Data(Self.prList.utf8)
            case "rollback":
                throw Self.failure(#"{"ok":false,"error":"changed","code":"changed_since","diff":"-y\n+y\n+z"}"#)
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
        let center = makeCenter(runner)
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        let diff = await center.rollback(10, force: false)
        XCTAssertEqual(diff, "-y\n+y\n+z")
        XCTAssertNil(center.cardErrors[10])
        XCTAssertNil(center.retries[10])
        let proposal = try XCTUnwrap(center.proposals?.value?.first { $0.id == 10 })
        let texts = CoachRollbackTexts(proposal)
        XCTAssertFalse(texts.offersForce)
        XCTAssertEqual(texts.body,
                       "CLAUDE.md on the default branch changed since the merge — revert it by hand in a pull request.")
        XCTAssertFalse(runner.invocations.contains { $0.contains("--force") }, "nothing forced")
    }

    func testPRRollbackRefusalOffersRetry() async {
        let runner = ScriptedCoachRunner { args in
            switch args.dropFirst().first {
            case "proposals": return Data(Self.prList.utf8)
            case "rollback":
                throw Self.prFailure(10, "pr_unreadable", CoachPRTexts.prUnreadable("#12"), "gh: offline")
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
        let center = makeCenter(runner)
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        let diff = await center.rollback(10, force: false)
        XCTAssertNil(diff)
        XCTAssertEqual(center.cardErrors[10], CoachPRTexts.prUnreadable("#12") + " (gh: offline)")
        XCTAssertEqual(center.retries[10], .rollback)

        runner.answer { args in
            if args.dropFirst().first == "rollback" {
                throw Self.prFailure(10, "origin_moved", CoachPRTexts.originMoved, "github.com/acme/other")
            }
            return Data(Self.prList.utf8)
        }
        _ = await center.rollback(10, force: false)
        XCTAssertEqual(center.cardErrors[10], CoachPRTexts.originMoved)
        XCTAssertNil(center.retries[10], "a moved origin is not retried")
    }

    func testSyncPRsReloadsWhenRowsChanged() async {
        let runner = ScriptedCoachRunner { args in
            switch args.dropFirst().first {
            case "sync-prs": return Data(#"{"ok":true,"changed":1,"sync_error":"","sync_code":""}"#.utf8)
            case "proposals": return Data(Self.prList.utf8)
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
        let center = makeCenter(runner)
        center.syncPRs()
        await runner.untilCalls { $0.contains(["coach", "proposals", "--status", "all", "--json"]) }
        XCTAssertEqual(runner.invocations.first, ["coach", "sync-prs", "--json"])
        await waitUntil { !center.syncing }
        XCTAssertNil(center.syncLine)
    }

    func testSyncPRsWithNothingChangedDoesNotReload() async {
        let runner = ScriptedCoachRunner { _ in Data(#"{"ok":true,"changed":0,"sync_error":"","sync_code":""}"#.utf8) }
        let center = makeCenter(runner)
        center.syncPRs()
        await waitUntil { !center.syncing }
        XCTAssertEqual(runner.invocations, [["coach", "sync-prs", "--json"]])
    }

    func testSyncPRsRunsOnceAtATime() async {
        let runner = ScriptedCoachRunner { _ in Data(#"{"ok":true,"changed":0,"sync_error":"","sync_code":""}"#.utf8) }
        runner.hold()
        let center = makeCenter(runner)
        center.syncPRs()
        await runner.untilCalls { !$0.isEmpty }
        center.syncPRs()
        center.syncPRs()
        XCTAssertTrue(center.syncing)
        runner.release(0)
        await waitUntil { !center.syncing }
        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// The real `coach sync-prs --json` of two unreadable rows: `sync_error` is Go's errors.Join of
    /// "syncing coach proposal N: <sentence> (<gh's words>)" lines. The owner's line takes none of it.
    nonisolated private static let joinedSyncError: String = {
        let rows = [
            "syncing coach proposal 10: Could not read pull request #12 from GitHub — try again. "
                + "(coach: pull request unreadable: gh: could not resolve host api.github.com)",
            "syncing coach proposal 11: Could not read pull request #14 from GitHub — try again. "
                + "(coach: pull request unreadable: gh: HTTP 502)"
        ]
        let object: [String: Any] = ["ok": true, "changed": 0, "sync_error": rows.joined(separator: "\n"),
                                     "sync_code": "pr_unreadable"]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? ""
    }()

    func testSyncPRsLineNeverShowsTheJoinedCLIError() async throws {
        let runner = ScriptedCoachRunner { _ in Data(Self.joinedSyncError.utf8) }
        let center = makeCenter(runner)
        center.syncPRs()
        await waitUntil { !center.syncing }
        let line = try XCTUnwrap(center.syncLine)
        XCTAssertEqual(line, CoachPRTexts.syncFailed)
        XCTAssertFalse(line.contains("proposal"), "no proposal id")
        XCTAssertFalse(line.contains("10") || line.contains("11"), "no proposal id")
        XCTAssertFalse(line.contains("gh:") || line.contains("("), "no gh words")
        XCTAssertFalse(line.contains("\n"), "one sentence, not one per row")
    }

    func testSyncPRsLines() async {
        let noGH = #"{"ok":true,"changed":0,"sync_error":"syncing coach proposal 10: Log in with `gh auth login` "#
            + #"to let Watchtower open the pull request. (workbenchgit: gh: not logged in)","sync_code":"no_gh"}"#
        let runner = ScriptedCoachRunner { _ in Data(noGH.utf8) }
        let center = makeCenter(runner)
        center.syncPRs()
        await waitUntil { !center.syncing }
        XCTAssertEqual(center.syncLine, CoachPRTexts.noGH)

        let timeout = #"{"ok":true,"changed":0,"sync_error":"syncing coach proposal 10: GitHub did not answer in "#
            + #"time; nothing changed — try again. (context deadline exceeded)","sync_code":"timeout"}"#
        runner.answer { _ in Data(timeout.utf8) }
        center.syncPRs()
        await waitUntil { !center.syncing }
        XCTAssertEqual(center.syncLine, CoachPRTexts.timeout)

        runner.answer { _ in throw Self.failure(#"{"ok":false,"error":"refused under an AI agent"}"#) }
        center.syncPRs()
        await waitUntil { !center.syncing }
        XCTAssertEqual(center.syncLine, CoachPRTexts.syncFailed)

        runner.answer { _ in Data(#"{"ok":true,"changed":0,"sync_error":"","sync_code":""}"#.utf8) }
        center.syncPRs()
        await waitUntil { !center.syncing }
        XCTAssertNil(center.syncLine, "a sync that read every PR clears the line")
    }

    /// A Roll Back refused while the PR could not be read leaves an error and a Retry; once a sync
    /// moves the proposal to rolled_back, the reload drops both (the Retry could only fail).
    func testStatusChangeOnReloadDropsTheCardsErrorAndRetry() async {
        let rolledBack = Self.prList.replacingOccurrences(of: #""status":"accepted""#, with: #""status":"rolled_back""#)
        let runner = ScriptedCoachRunner { args in
            switch args.dropFirst().first {
            case "proposals": return Data(Self.prList.utf8)
            case "rollback": throw Self.prFailure(10, "pr_unreadable", CoachPRTexts.prUnreadable("#12"), "gh: offline")
            default: return Data(#"{"ok":true}"#.utf8)
            }
        }
        let center = makeCenter(runner)
        center.refreshProposals()
        await waitUntil { center.proposals?.value != nil }
        _ = await center.rollback(10, force: false)
        XCTAssertEqual(center.retries[10], .rollback)

        // A reload with the same status keeps them.
        let renamed = Self.prList.replacingOccurrences(of: #""title":"Fixtures""#, with: #""title":"Fixtures 2""#)
        runner.answer { args in
            if args.dropFirst().first == "proposals" { return Data(renamed.utf8) }
            return Data(#"{"ok":true}"#.utf8)
        }
        center.refreshProposals()
        await waitUntil { center.proposals?.value?.first { $0.id == 10 }?.title == "Fixtures 2" }
        XCTAssertNotNil(center.cardErrors[10])
        XCTAssertEqual(center.retries[10], .rollback)

        runner.answer { args in
            if args.dropFirst().first == "sync-prs" {
                return Data(#"{"ok":true,"changed":1,"sync_error":"","sync_code":""}"#.utf8)
            }
            return Data(rolledBack.utf8)
        }
        center.syncPRs()
        await waitUntil { center.proposals?.value?.first { $0.id == 10 }?.status == "rolled_back" }
        XCTAssertNil(center.cardErrors[10])
        XCTAssertNil(center.retries[10])
    }
}
