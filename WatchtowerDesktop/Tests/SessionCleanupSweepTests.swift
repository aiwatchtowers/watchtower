import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Go-shaped sweep JSON (spec 2026-10-12-session-cleanup §4.1/§9).
private enum SweepFixture {
    static let oldWorktree = "worktree:/tmp/example/.claude/worktrees/old"
    static let recentWorktree = "worktree:/tmp/example/.claude/worktrees/recent"
    static let oldBranch = "branch:feat/old"

    /// A removable 2 GB worktree, a kept 5 GB one (a recent session's), a
    /// removable branch of an unknown owner and a removable item of a kind
    /// this build does not know.
    static let plan = Data("""
    {"workbench_id":2,"mode":"plan","sweep":true,"default_branch":"main","items":[
      {"key":"\(oldWorktree)","kind":"worktree","name":"old","branch":"feat/old",
       "bytes":2000000000,"bytes_known":true,"action":"remove",
       "owner":{"session_id":4,"title":"Old work","last_active":"2026-09-01T10:00:00Z"}},
      {"key":"\(recentWorktree)","kind":"worktree","name":"recent","branch":"feat/recent",
       "bytes":5000000000,"bytes_known":true,"action":"keep","reason":"session_recent",
       "owner":{"session_id":7,"title":"Recent work"}},
      {"key":"\(oldBranch)","kind":"branch","name":"feat/old","action":"remove","owner":{"unknown":true}},
      {"key":"gizmo:1","kind":"gizmo","name":"g","action":"remove","owner":{"unknown":true}}
    ]}
    """.utf8)

    /// Under the hint's line: the removable worktree holds 0.9 GB; the kept
    /// 5 GB one is not space the sweep can free.
    static let smallPlan = Data("""
    {"workbench_id":2,"mode":"plan","sweep":true,"items":[
      {"key":"\(oldWorktree)","kind":"worktree","name":"old","bytes":900000000,"bytes_known":true,"action":"remove"},
      {"key":"\(recentWorktree)","kind":"worktree","name":"recent","bytes":5000000000,"bytes_known":true,
       "action":"keep","reason":"session_recent"}
    ]}
    """.utf8)

    /// Under the line by what was measured, but one removable worktree went
    /// over Go's size budget.
    static let unmeasuredPlan = Data("""
    {"workbench_id":2,"mode":"plan","sweep":true,"items":[
      {"key":"\(oldWorktree)","kind":"worktree","name":"old","bytes":0,"bytes_known":false,"action":"remove"},
      {"key":"\(recentWorktree)","kind":"worktree","name":"recent","bytes":100,"bytes_known":true,"action":"remove"}
    ]}
    """.utf8)

    static let bundle = "lsreg:/tmp/example/.claude/worktrees/old/build/Old.app"

    /// `plan` with the old worktree named by its folder's base name, as Go
    /// names it (its root is the key's), and a LaunchServices entry of a
    /// bundle built inside it, which names that root.
    static let planWithBundle = Data("""
    {"workbench_id":2,"mode":"plan","sweep":true,"default_branch":"main","items":[
      {"key":"\(oldWorktree)","kind":"worktree","name":"old","branch":"feat/old",
       "bytes":2000000000,"bytes_known":true,"action":"remove",
       "owner":{"session_id":4,"title":"Old work","last_active":"2026-09-01T10:00:00Z"}},
      {"key":"\(recentWorktree)","kind":"worktree","name":"recent","branch":"feat/recent",
       "bytes":5000000000,"bytes_known":true,"action":"keep","reason":"session_recent",
       "owner":{"session_id":7,"title":"Recent work"}},
      {"key":"\(oldBranch)","kind":"branch","name":"feat/old","action":"remove","owner":{"unknown":true}},
      {"key":"\(bundle)","kind":"lsreg","name":"Old.app","detail":"/tmp/example/.claude/worktrees/old/build/Old.app",
       "worktree":"/tmp/example/.claude/worktrees/old","action":"remove"},
      {"key":"gizmo:1","kind":"gizmo","name":"g","action":"remove","owner":{"unknown":true}}
    ]}
    """.utf8)

    /// A branch with no worktree beside an item of a kind this build does
    /// not know.
    static let branchOnlyPlan = Data("""
    {"workbench_id":2,"mode":"plan","sweep":true,"items":[
      {"key":"\(oldBranch)","kind":"branch","name":"feat/old","action":"remove","owner":{"unknown":true}},
      {"key":"gizmo:1","kind":"gizmo","name":"g","action":"remove","owner":{"unknown":true}}
    ]}
    """.utf8)

    static let applied = Data("""
    {"workbench_id":2,"mode":"apply","sweep":true,"items":[
      {"key":"\(oldWorktree)","kind":"worktree","name":"old","action":"remove","done":true}
    ],"removed_bytes":2000000000,"removed_bytes_known":true,"summary":"1 worktree removed (~2.0 GB)"}
    """.utf8)
}

/// The Clean Up screen (board #1107, spec 2026-10-26-worktree-cleanup-screen
/// §3/§5/§8) — opened on the whole workbench (**Clean Up Old Worktrees…**,
/// board #535) or on one session — and the one-time hint (open question 2 of
/// the 2026-10-12 cleanup spec, owner approved): the argv, nothing ticked,
/// only ticked known keys applied, runs that outlive the page, one apply per
/// workbench. No subprocess is spawned: the streamer is a double.
@MainActor
final class SessionCleanupSweepTests: XCTestCase {
    private let workbenchID: Int64 = 2
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var streamers: [RepliedCleanupStreamer] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionCleanupSweepTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        streamers.forEach { $0.finishAll() }
        streamers = []
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: RepliedCleanupStreamer, live: Set<Int64> = []) -> (WorkbenchesViewModel, SessionCleanupCenter) {
        streamers.append(runner)
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        let cleanup = SessionCleanupCenter(runner: nil, streamer: runner)
        cleanup.liveSessionIDs = { live }
        vm.sessionCleanup = cleanup
        // The page has been on screen long enough unless a test holds it.
        vm.cleanupHintSleep = { _ in }
        return (vm, cleanup)
    }

    private func applyCalls(_ runner: RepliedCleanupStreamer) -> [[String]] {
        runner.calls.map(\.args).filter { $0.contains("--apply") }
    }

    private func readyPlan(_ center: SessionCleanupCenter, _ scope: SessionCleanupScope? = nil) throws -> SessionCleanupPlan {
        let phase = center.cleanupPhase(for: scope ?? .workbench(workbenchID))
        guard case let .ready(plan) = phase else {
            XCTFail("expected a ready plan, got \(phase)")
            throw CancellationError()
        }
        return plan
    }

    /// The owner ticks `ticks` on the open screen.
    private func tick(_ vm: WorkbenchesViewModel, _ ticks: Set<String>) {
        vm.cleanupScreens[workbenchID]?.ticks = ticks
    }

    // MARK: - Plan and apply

    func testSweepPlanPassesAllLiveSessions() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner, live: [11, 3, 7])

        await vm.openCleanupScreen(projectID: workbenchID).value

        XCTAssertEqual(runner.calls.map(\.args), [[
            "workbench", "cleanup", "--workbench=2", "--sweep",
            "--live-session=3", "--live-session=7", "--live-session=11", "--json", "--stream"
        ]], "a sweep names no session and passes every live terminal")
        XCTAssertNil(runner.calls.first?.environment[SessionCleanupCenter.terminalSessionVariable])
    }

    func testSweepTicksNothingByDefault() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        await vm.openCleanupScreen(projectID: workbenchID).value
        let plan = try readyPlan(cleanup)
        XCTAssertFalse(plan.knownRemovableKeys.isEmpty, "the fixture has removable items")

        let ticks = try XCTUnwrap(vm.cleanupScreens[workbenchID]).ticks
        XCTAssertEqual(ticks, [], "a sweep arrives with nothing ticked")
        XCTAssertEqual(vm.cleanupScreenModel(projectID: workbenchID)?.applyKeys(for: ticks), [])
        let ok = await vm.applyCleanupScreen(projectID: workbenchID)
        XCTAssertFalse(ok)
        XCTAssertEqual(applyCalls(runner), [], "with nothing ticked nothing runs")
    }

    func testSessionScopeTicksNothing() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan)])
        let (vm, cleanup) = makeVM(runner, live: [9])

        await vm.openCleanupScreen(projectID: workbenchID, sessionID: 9).value

        XCTAssertEqual(runner.calls.map(\.args), [[
            "workbench", "cleanup", "--session=9", "--workbench=2", "--live-session=9", "--json", "--stream"
        ]], "the session's own plan, every live terminal passed")
        XCTAssertFalse(try readyPlan(cleanup, .session(9)).knownRemovableKeys.isEmpty, "the fixture has removable items")
        XCTAssertEqual(vm.cleanupScreens[workbenchID]?.scope, .session(9))
        XCTAssertEqual(vm.cleanupScreens[workbenchID]?.ticks, [], "nothing is ticked in a session's scope either")
        XCTAssertTrue(vm.cleanupScreenShows(sessionID: 9))
        XCTAssertFalse(vm.cleanupScreenShows(sessionID: 4))
        let ok = await vm.applyCleanupScreen(projectID: workbenchID)
        XCTAssertFalse(ok)
        XCTAssertEqual(applyCalls(runner), [])
    }

    /// PROJ-18, 2026-10-26 amendment (owner approved, ask #633): a worktree
    /// row is the worktree, its branch when that branch item is `remove`,
    /// and its bundles' LaunchServices entries; a kept item, a stray key
    /// and an unknown kind are never sent, whatever the ticks say.
    func testSweepAppliesOnlyTickedKeys() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.planWithBundle), .success(SweepFixture.applied)])
        let (vm, cleanup) = makeVM(runner, live: [7, 3])
        await vm.openCleanupScreen(projectID: workbenchID).value

        tick(vm, [SweepFixture.oldWorktree, SweepFixture.recentWorktree, "bogus", "gizmo:1"])
        let ok = await vm.applyCleanupScreen(projectID: workbenchID)

        XCTAssertTrue(ok)
        XCTAssertEqual(applyCalls(runner), [[
            "workbench", "cleanup", "--workbench=2", "--sweep", "--live-session=3", "--live-session=7",
            "--apply", "--item=\(SweepFixture.oldWorktree)", "--item=\(SweepFixture.oldBranch)",
            "--item=\(SweepFixture.bundle)", "--json", "--stream"
        ]])
        XCTAssertEqual(vm.cleanupScreens[workbenchID]?.sentKeys,
                       [SweepFixture.oldWorktree, SweepFixture.oldBranch, SweepFixture.bundle])
        guard case let .done(result) = cleanup.cleanupPhase(for: .workbench(workbenchID)) else {
            return XCTFail("the open screen shows the result")
        }
        XCTAssertEqual(result.summary, "1 worktree removed (~2.0 GB)")
        vm.closeCleanupScreen(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "closing the screen forgets it")
    }

    func testSweepNeverAppliesUnknownKinds() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.branchOnlyPlan), .success(SweepFixture.applied)])
        let (vm, cleanup) = makeVM(runner)
        await vm.openCleanupScreen(projectID: workbenchID).value
        XCTAssertFalse(try readyPlan(cleanup).knownRemovableKeys.contains("gizmo:1"))

        tick(vm, ["gizmo:1"])
        let onlyUnknown = await vm.applyCleanupScreen(projectID: workbenchID)
        XCTAssertFalse(onlyUnknown)
        XCTAssertEqual(applyCalls(runner), [], "an unknown kind alone runs nothing")

        tick(vm, ["gizmo:1", SweepFixture.oldBranch])
        await vm.applyCleanupScreen(projectID: workbenchID)
        XCTAssertEqual(applyCalls(runner).first?.filter { $0.hasPrefix("--item") }, ["--item=\(SweepFixture.oldBranch)"])
    }

    /// The screen's state is page state: nothing of it reaches the saved
    /// workspace layout.
    func testScreenStateIsNeverSaved() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        let before = vm.layout(projectID: workbenchID)

        await vm.openCleanupScreen(projectID: workbenchID).value
        tick(vm, [SweepFixture.oldWorktree])

        XCTAssertEqual(vm.layout(projectID: workbenchID), before)
        let encoded = try XCTUnwrap(String(bytes: JSONEncoder().encode(vm.layout(projectID: workbenchID)), encoding: .utf8))
        XCTAssertFalse(encoded.lowercased().contains("clean"), encoded)
        XCTAssertNil(vm.layouts[workbenchID], "opening the screen writes no layout")
        XCTAssertNil(defaults.data(forKey: WorkspaceLayout.key(workbenchID: workbenchID)))
    }

    // MARK: - Scope

    func testWideningTheScopePlansTheWorkbench() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan), .success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        vm.openCleanupScreen(projectID: workbenchID, sessionID: 9)
        await waitUntil("the session plan") { runner.heldCount == 1 }

        let widened = vm.widenCleanupScope(projectID: workbenchID)
        await waitUntil("the workbench plan") { runner.calls.count == 2 }
        runner.holdsCalls = false
        runner.release()
        await widened.value

        XCTAssertEqual(runner.calls.last?.args, [
            "workbench", "cleanup", "--workbench=2", "--sweep", "--json", "--stream"
        ])
        XCTAssertGreaterThan(runner.runs[0].stopCount, 0, "the session plan was stopped")
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(9)), .idle)
        XCTAssertEqual(vm.cleanupScreens[workbenchID]?.scope, .workbench(workbenchID))
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)
    }

    /// Opening another scope closes the shown one: its ready plan or its
    /// result is forgotten, so nothing stale comes back and the scope is
    /// free again (a placed session's cleanup, the hint).
    func testChangingTheScopeForgetsTheOldScopesPhase() async throws {
        let runner = RepliedCleanupStreamer(replies: [
            .success(CleanupFixture.plan), .success(SweepFixture.plan),
            .success(CleanupFixture.plan), .success(CleanupFixture.applied), .success(SweepFixture.plan)
        ])
        let (vm, cleanup) = makeVM(runner)

        // A ready plan of session 9, then the workbench.
        await vm.openCleanupScreen(projectID: workbenchID, sessionID: 9).value
        _ = try readyPlan(cleanup, .session(9))
        await vm.openCleanupScreen(projectID: workbenchID).value
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(9)), .idle, "the ready plan was forgotten")
        XCTAssertFalse(vm.cleanupScreenShows(sessionID: 9))

        // A finished apply of session 9, then the workbench again.
        await vm.openCleanupScreen(projectID: workbenchID, sessionID: 9).value
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "the workbench's plan went too")
        tick(vm, ["worktree:/tmp/example/.claude/worktrees/x"])
        let ok = await vm.applyCleanupScreen(projectID: workbenchID)
        XCTAssertTrue(ok)
        guard case .done = cleanup.cleanupPhase(for: .session(9)) else { return XCTFail("expected the result") }
        await vm.openCleanupScreen(projectID: workbenchID).value
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(9)), .idle, "the result was forgotten")
        XCTAssertEqual(vm.cleanupScreens[workbenchID]?.scope, .workbench(workbenchID))
    }

    // MARK: - One apply at a time

    func testRefreshAndCleanUpDisabledWhileApplying() async throws {
        for sessionID in [nil, 9] as [Int64?] {
            let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan), .success(SweepFixture.applied)])
            let (vm, _) = makeVM(runner)
            await vm.openCleanupScreen(projectID: workbenchID, sessionID: sessionID).value
            XCTAssertTrue(vm.canRefreshCleanup(projectID: workbenchID))
            tick(vm, [SweepFixture.oldWorktree])

            runner.holdsCalls = true
            let apply = Task { await vm.applyCleanupScreen(projectID: workbenchID) }
            await waitUntil("the apply") { runner.heldCount == 1 }
            XCTAssertFalse(vm.canRefreshCleanup(projectID: workbenchID), "scope \(String(describing: sessionID))")
            let second = await vm.applyCleanupScreen(projectID: workbenchID)
            XCTAssertFalse(second, "a second Clean Up… launches nothing")
            XCTAssertEqual(applyCalls(runner).count, 1)

            runner.release()
            let ok = await apply.value
            XCTAssertTrue(ok)
            XCTAssertTrue(vm.canRefreshCleanup(projectID: workbenchID), "free again once it ended")
        }
    }

    func testApplyIsNeverStoppedByRefreshOrScopeChange() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, cleanup) = makeVM(runner)
        await vm.openCleanupScreen(projectID: workbenchID, sessionID: 9).value
        tick(vm, ["worktree:/tmp/example/.claude/worktrees/x"])

        runner.holdsCalls = true
        let apply = Task { await vm.applyCleanupScreen(projectID: workbenchID) }
        await waitUntil("the apply") { runner.heldCount == 1 }
        vm.refreshCleanup(projectID: workbenchID)
        vm.widenCleanupScope(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 2, "neither started a run")
        XCTAssertEqual(vm.cleanupScreens[workbenchID]?.scope, .session(9))

        runner.release()
        let ok = await apply.value
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.runs[1].stopCount, 0, "the apply's stream was never stopped")
        guard case .done = cleanup.cleanupPhase(for: .session(9)) else {
            return XCTFail("its done lands, got \(cleanup.cleanupPhase(for: .session(9)))")
        }
    }

    // MARK: - Retry

    func testRetryAfterAFailedApplyReappliesTheTicks() async throws {
        let runner = RepliedCleanupStreamer(replies: [
            .success(SweepFixture.plan), .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "git missing")),
            .success(SweepFixture.applied)
        ])
        let (vm, cleanup) = makeVM(runner)
        await vm.openCleanupScreen(projectID: workbenchID).value
        tick(vm, [SweepFixture.oldWorktree])
        let failed = await vm.applyCleanupScreen(projectID: workbenchID)
        XCTAssertFalse(failed)
        guard case .failed = cleanup.cleanupPhase(for: .workbench(workbenchID)) else { return XCTFail("expected a failure") }

        vm.retryCleanup(projectID: workbenchID)
        await waitUntil("the second apply") {
            if case .done = cleanup.cleanupPhase(for: .workbench(self.workbenchID)) { return true }
            return false
        }

        XCTAssertEqual(applyCalls(runner).count, 2)
        XCTAssertEqual(applyCalls(runner)[1], applyCalls(runner)[0], "the same ticks applied again")
        XCTAssertNil(vm.sessionErrors[workbenchID], "the open screen showed the failure")
    }

    func testRetryAfterAFailedPlanPlansAgain() async throws {
        let runner = RepliedCleanupStreamer(replies: [
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "git missing")), .success(SweepFixture.plan)
        ])
        let (vm, cleanup) = makeVM(runner)
        await vm.openCleanupScreen(projectID: workbenchID).value
        guard case .failed = cleanup.cleanupPhase(for: .workbench(workbenchID)) else { return XCTFail("expected a failure") }

        vm.retryCleanup(projectID: workbenchID)
        await waitUntil("the second plan") {
            if case .ready = cleanup.cleanupPhase(for: .workbench(self.workbenchID)) { return true }
            return false
        }

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(applyCalls(runner), [], "a failed plan is planned again, never applied")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)
    }

    // MARK: - Leaving the page

    /// The screen starts the plan, the page goes away: the plan runs on;
    /// then an apply goes on after the screen closed and is forgotten once
    /// it ended.
    func testSweepSurvivesLeavingThePage() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan), .success(SweepFixture.applied)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)

        let screenTask = Task { await vm.openCleanupScreen(projectID: workbenchID).value }
        while runner.heldCount == 0 { await Task.yield() }
        screenTask.cancel()
        runner.release()
        await screenTask.value
        await cleanup.runningPlan(for: .workbench(workbenchID))?.value
        XCTAssertEqual(runner.cancelledCount, 0, "the plan's CLI was not stopped")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)

        tick(vm, [SweepFixture.oldWorktree])
        let apply = Task { await vm.applyCleanupScreen(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        apply.cancel()
        vm.closeCleanupScreen(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .applying, "the apply goes on")
        runner.release()
        let ok = await apply.value

        XCTAssertTrue(ok)
        XCTAssertEqual(runner.cancelledCount, 0, "the apply's CLI was not stopped")
        XCTAssertEqual(applyCalls(runner).count, 1)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "forgotten once it ended")
        XCTAssertNil(vm.sessionErrors[workbenchID])
    }

    // MARK: - One-time hint

    func testSweepHintShownOnceAboveOneGigabyte() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner, live: [3])

        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(vm.cleanupHints[workbenchID], "Old worktrees use ~2.0 GB.",
                       "only the removable worktree counts, not the kept 5 GB")
        XCTAssertTrue(defaults.bool(forKey: "projects.cleanupHintShown.\(workbenchID)"),
                      "the key is written as the hint goes up on the page")
        XCTAssertEqual(runner.calls.first?.args,
                       ["workbench", "cleanup", "--workbench=2", "--sweep", "--live-session=3", "--json", "--stream"])
        XCTAssertEqual(try? readyPlan(cleanup).items.count, 4, "the hint's plan is kept for the screen")

        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 1, "never planned again")
        vm.dismissCleanupHint(projectID: workbenchID)
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "the ✕ forgets the hint's plan")

        // The next launch: shown before, so never planned for again.
        let (next, _) = makeVM(runner)
        await next.watchCleanupHint(projectID: workbenchID)
        XCTAssertNil(next.cleanupHints[workbenchID])
        XCTAssertEqual(runner.calls.count, 1, "no sweep once the hint was shown")
    }

    func testSweepHintStaysAwayAtOrBelowOneGigabyte() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.smallPlan)])
        let (vm, _) = makeVM(runner)

        await vm.watchCleanupHint(projectID: workbenchID)

        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertFalse(defaults.bool(forKey: WorkbenchesViewModel.cleanupHintShownKey(workbenchID)),
                       "never shown, so a later check may still find more")
        XCTAssertNil(SessionCleanupPresentation.sweepHint(SessionCleanupPlan(items: [
            SessionCleanupItem(key: "worktree:x", kind: .worktree, bytes: 1_000_000_000, bytesKnown: true, action: .remove)
        ])), "exactly 1 GB is not over it")
    }

    /// At or below the line the check time is stored: no hint plan for 7
    /// days, across launches; then one again.
    func testBelowTheLineRechecksAfterSevenDays() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.smallPlan)])
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let (vm, _) = makeVM(runner)
        vm.cleanupHintNow = { start }
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(defaults.double(forKey: "projects.cleanupHintCheckedAt.\(workbenchID)"),
                       start.timeIntervalSince1970)

        let (sixDaysOn, _) = makeVM(runner)
        sixDaysOn.cleanupHintNow = { start.addingTimeInterval(6 * 86400) }
        await sixDaysOn.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 1, "checked 6 days ago: no plan")

        let (sevenDaysOn, _) = makeVM(runner)
        sevenDaysOn.cleanupHintNow = { start.addingTimeInterval(7 * 86400) }
        await sevenDaysOn.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 2, "7 days on: planned again")
    }

    /// An unmeasured removable worktree leaves the answer open: no hint,
    /// and no 7-day snooze either.
    func testUnmeasuredWorktreeIsNotSnoozed() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.unmeasuredPlan)])
        let (vm, _) = makeVM(runner)

        await vm.watchCleanupHint(projectID: workbenchID)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertNil(defaults.object(forKey: WorkbenchesViewModel.cleanupHintCheckedAtKey(workbenchID)))
    }

    /// A check stamp in the future (the clock was set back since) is due.
    func testFutureCheckStampIsDue() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.smallPlan)])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        defaults.set(now.timeIntervalSince1970 + 86400, forKey: WorkbenchesViewModel.cleanupHintCheckedAtKey(workbenchID))
        let (vm, _) = makeVM(runner)
        vm.cleanupHintNow = { now }

        await vm.watchCleanupHint(projectID: workbenchID)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(defaults.double(forKey: WorkbenchesViewModel.cleanupHintCheckedAtKey(workbenchID)),
                       now.timeIntervalSince1970, "the stamp is corrected")
    }

    /// The page went away just after the plan landed: the plan is not kept,
    /// so the next visit can hint.
    func testPageLeftAfterThePlanLandedLetsTheNextVisitHint() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        await cleanup.startStreamedPlan(.workbench(workbenchID), workbenchID: workbenchID).value
        guard case .ready = cleanup.cleanupPhase(for: .workbench(workbenchID)) else { return XCTFail("no plan") }

        vm.finishCleanupHint(projectID: workbenchID, center: cleanup, pageLeft: true)

        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "the landed plan is forgotten")
        XCTAssertNil(vm.cleanupHints[workbenchID])
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertNotNil(vm.cleanupHints[workbenchID], "the next visit hints")
    }

    /// A stalled hint plan is stopped at its time limit and frees the slot.
    func testHintPlanStopsAtItsTimeLimit() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        vm.cleanupHintTimeLimit = .milliseconds(20)

        let page = Task { await vm.watchCleanupHint(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(300))
        runner.release()
        await page.value

        XCTAssertEqual(runner.cancelledCount, 1, "the CLI was stopped")
        XCTAssertNil(vm.cleanupHintRunning, "the slot is free")
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle)
    }

    /// The plan starts only once the page stayed on screen 30 s; leaving it
    /// before cancels the start.
    func testHintWaitsForThePageToStayOnScreen() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        let gate = HintGate()
        vm.cleanupHintSleep = { try await gate.wait($0) }

        let page = Task { await vm.watchCleanupHint(projectID: workbenchID) }
        while gate.waited.isEmpty { await Task.yield() }
        XCTAssertEqual(gate.waited, [.seconds(30)])
        XCTAssertEqual(runner.calls.count, 0, "nothing runs during the wait")
        page.cancel()
        gate.open()
        await page.value

        XCTAssertEqual(runner.calls.count, 0, "the page left: no plan")
        XCTAssertNil(vm.cleanupHints[workbenchID])
    }

    /// Leaving the page stops a running hint plan; nothing is stored, so a
    /// later visit plans again.
    func testLeavingThePageStopsARunningHintPlan() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)

        let page = Task { await vm.watchCleanupHint(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        page.cancel()
        runner.release()
        await page.value

        XCTAssertEqual(runner.cancelledCount, 1, "the CLI was stopped")
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertNil(defaults.object(forKey: WorkbenchesViewModel.cleanupHintCheckedAtKey(workbenchID)))
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle)

        runner.holdsCalls = false
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 2, "the next visit tries again")
        XCTAssertNotNil(vm.cleanupHints[workbenchID])
    }

    /// One hint plan at a time, app-wide.
    func testOneHintPlanAtATime() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, _) = makeVM(runner)

        let first = Task { await vm.watchCleanupHint(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        await vm.watchCleanupHint(projectID: 3)
        XCTAssertEqual(runner.calls.count, 1, "workbench 3 waits for another visit")

        runner.release()
        await first.value
        runner.holdsCalls = false
        await vm.watchCleanupHint(projectID: 3)
        XCTAssertEqual(runner.calls.last?.args.contains("--workbench=3"), true, "free again once it ended")
    }

    /// The screen opened while the hint plan runs: the screen's plan
    /// stays, and no hint goes up behind it.
    func testScreenOpenedMidHintKeepsTheScreensPlan() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)

        let page = Task { await vm.watchCleanupHint(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        let screen = vm.openCleanupScreen(projectID: workbenchID)
        while runner.heldCount < 2 { await Task.yield() }
        runner.release()
        await page.value
        await screen.value

        XCTAssertEqual(try readyPlan(cleanup).items.count, 4, "the screen's plan is kept")
        XCTAssertNil(vm.cleanupHints[workbenchID])
    }

    /// Opening the sweep answers the hint: it goes and never comes back.
    func testOpeningTheSweepAnswersTheHint() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertNotNil(vm.cleanupHints[workbenchID])

        await vm.openCleanupScreen(projectID: workbenchID).value

        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertTrue(defaults.bool(forKey: WorkbenchesViewModel.cleanupHintShownKey(workbenchID)))
    }

    /// The hint's **Clean Up…**: the screen shows the plan the hint already
    /// made instead of walking every worktree again (board #704).
    func testScreenOpenedFromTheHintReusesItsPlan() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        await vm.watchCleanupHint(projectID: workbenchID)

        await vm.openCleanupScreen(projectID: workbenchID).value

        XCTAssertEqual(runner.calls.count, 1, "no second plan")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)
    }

    /// Closing the screen while it plans leaves the plan running; reopening
    /// waits for that plan instead of starting over (board #704).
    func testClosingTheScreenMidPlanKeepsThePlanForTheNextOpen() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        let first = Task { await vm.openCleanupScreen(projectID: workbenchID).value }
        while runner.heldCount == 0 { await Task.yield() }
        first.cancel()
        vm.closeCleanupScreen(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .planning, "the plan goes on")

        var secondEnded = false
        let second = Task {
            await vm.openCleanupScreen(projectID: workbenchID).value
            secondEnded = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(secondEnded, "the reopened screen waits for the running plan")
        runner.release()
        await second.value

        XCTAssertEqual(runner.calls.count, 1, "the reopened screen waits for the running plan")
        XCTAssertEqual(runner.cancelledCount, 0)
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)

        // A ready plan is forgotten on close: the next open plans afresh.
        vm.closeCleanupScreen(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle)
    }

    /// A screen's plan stalled on a read is stopped at its time limit and
    /// shows a failure, closed and reopened or not (board #704).
    func testStalledScreenPlanFailsAtItsTimeLimit() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        vm.cleanupHintTimeLimit = .milliseconds(50)
        let first = Task { await vm.openCleanupScreen(projectID: workbenchID).value }
        while runner.heldCount == 0 { await Task.yield() }
        first.cancel()
        vm.closeCleanupScreen(projectID: workbenchID)
        let reopened = Task { await vm.openCleanupScreen(projectID: workbenchID).value }
        try await Task.sleep(for: .milliseconds(150))
        runner.release() // the real runner ends the child on cancel
        await reopened.value

        guard case let .failed(message) = cleanup.cleanupPhase(for: .workbench(workbenchID)) else {
            return XCTFail("expected the stopped plan to fail, got \(cleanup.cleanupPhase(for: .workbench(workbenchID)))")
        }
        XCTAssertTrue(message.contains("was stopped"), message)
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertEqual(runner.calls.count, 1, "the reopened screen waited for the same plan")
    }

    /// A ready plan older than the reuse window is planned again.
    func testOldReadyPlanIsPlannedAgain() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan), .success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        cleanup.now = { clock }
        await vm.watchCleanupHint(projectID: workbenchID)
        clock += WorkbenchesViewModel.sweepPlanReuseWindow + 1

        await vm.openCleanupScreen(projectID: workbenchID).value

        XCTAssertEqual(runner.calls.count, 2, "a stale hint plan is not shown")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)
    }

    /// Opening the sweep before the hint plan ever ran answers it too.
    func testNoHintSweepOnceTheScreenWasOpened() async {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        vm.cleanupScreens[workbenchID] = CleanupScreenState(scope: .workbench(workbenchID))

        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 0, "not while the screen is open")

        await vm.openCleanupScreen(projectID: workbenchID).value
        vm.closeCleanupScreen(projectID: workbenchID)
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 1, "only the screen's plan ran")
        XCTAssertNil(vm.cleanupHints[workbenchID])
    }

    /// No hint plan and no hint while the screen is open on the workbench,
    /// in either scope; the hint's ✕ leaves the screen's plan alone.
    func testOpenScreenBlocksTheHint() async throws {
        let runner = RepliedCleanupStreamer(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        for scope in [SessionCleanupScope.workbench(workbenchID), .session(9)] {
            vm.cleanupScreens[workbenchID] = CleanupScreenState(scope: scope)
            await vm.watchCleanupHint(projectID: workbenchID)
            XCTAssertEqual(runner.calls.count, 0, "no hint plan while the screen is open on \(scope)")
        }

        // A hint plan that lands while a session's screen is open puts up
        // nothing and is dropped unchecked: a later visit tries again.
        await cleanup.startStreamedPlan(.workbench(workbenchID), workbenchID: workbenchID).value
        vm.finishCleanupHint(projectID: workbenchID, center: cleanup, pageLeft: false)
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle)
        XCTAssertFalse(vm.cleanupHintChecked.contains(workbenchID))

        // On the workbench scope the plan is the screen's: kept, no hint.
        vm.cleanupScreens[workbenchID] = CleanupScreenState(scope: .workbench(workbenchID))
        await cleanup.startStreamedPlan(.workbench(workbenchID), workbenchID: workbenchID).value
        vm.finishCleanupHint(projectID: workbenchID, center: cleanup, pageLeft: false)
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4, "the screen's plan is kept")
        vm.dismissCleanupHint(projectID: workbenchID)
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4, "the ✕ leaves the screen's plan alone")
    }
}

/// The hint's 30 s wait, held until `open()`; throws when its task was
/// cancelled, as `Task.sleep` does.
@MainActor
private final class HintGate {
    private(set) var waited: [Duration] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait(_ duration: Duration) async throws {
        waited.append(duration)
        await withCheckedContinuation { waiting.append($0) }
        try Task.checkCancellation()
    }

    func open() {
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}
