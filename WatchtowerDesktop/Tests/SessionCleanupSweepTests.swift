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

    static let applied = Data("""
    {"workbench_id":2,"mode":"apply","sweep":true,"items":[
      {"key":"\(oldWorktree)","kind":"worktree","name":"old","action":"remove","done":true}
    ],"removed_bytes":2000000000,"removed_bytes_known":true,"summary":"1 worktree removed (~2.0 GB)"}
    """.utf8)
}

/// **Clean Up Old Worktrees…** (board #535, spec 2026-10-12-session-cleanup
/// §9/§12) and its one-time hint (open question 2, owner approved): the
/// sweep's argv, nothing ticked, only ticked known keys applied, runs that
/// outlive the page. No subprocess is spawned: the runner is a double.
@MainActor
final class SessionCleanupSweepTests: XCTestCase {
    private let workbenchID: Int64 = 2
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionCleanupSweepTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: FakeSessionCleanupRunner, live: Set<Int64> = []) -> (WorkbenchesViewModel, SessionCleanupCenter) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        let cleanup = SessionCleanupCenter(runner: runner)
        cleanup.liveSessionIDs = { live }
        vm.sessionCleanup = cleanup
        return (vm, cleanup)
    }

    private func applyCalls(_ runner: FakeSessionCleanupRunner) -> [[String]] {
        runner.calls.map(\.args).filter { $0.contains("--apply") }
    }

    private func readyPlan(_ center: SessionCleanupCenter) throws -> SessionCleanupPlan {
        let phase = center.cleanupPhase(for: .workbench(workbenchID))
        guard case let .ready(plan) = phase else {
            XCTFail("expected a ready sweep plan, got \(phase)")
            throw CancellationError()
        }
        return plan
    }

    // MARK: - Plan and apply

    func testSweepPlanPassesAllLiveSessions() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner, live: [11, 3, 7])

        await vm.planSweepForSheet(projectID: workbenchID)

        XCTAssertEqual(runner.calls.map(\.args), [[
            "workbench", "cleanup", "--workbench=2", "--sweep",
            "--live-session=3", "--live-session=7", "--live-session=11", "--json"
        ]], "a sweep names no session and passes every live terminal")
        XCTAssertNil(runner.calls.first?.environment[SessionCleanupCenter.terminalSessionVariable])
    }

    func testSweepTicksNothingByDefault() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        await vm.planSweepForSheet(projectID: workbenchID)
        let plan = try readyPlan(cleanup)
        XCTAssertFalse(plan.knownRemovableKeys.isEmpty, "the fixture has removable items")

        XCTAssertEqual(plan.initialTicks, [], "a sweep arrives with nothing ticked")
        XCTAssertEqual(vm.sweepCleanupChoice(projectID: workbenchID, ticked: plan.initialTicks), [])
        let ok = await vm.applySweepCleanup(projectID: workbenchID, ticked: plan.initialTicks)
        XCTAssertFalse(ok)
        XCTAssertEqual(applyCalls(runner), [], "with nothing ticked nothing runs")

        // The session sheet still ticks every removable item of a known kind.
        let sessionPlan = try JSONDecoder().decode(SessionCleanupPlan.self, from: CleanupFixture.plan)
        XCTAssertEqual(sessionPlan.initialTicks, Set(CleanupFixture.plannedKeys))
    }

    func testSweepAppliesOnlyTickedKeys() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan), .success(SweepFixture.applied)])
        let (vm, cleanup) = makeVM(runner, live: [7, 3])
        vm.sweepSheetAppeared(projectID: workbenchID)
        await vm.planSweepForSheet(projectID: workbenchID)

        // The removable branch is left unticked; a kept item and a stray key
        // cannot be applied whatever the ticks say.
        let ticked: Set = [SweepFixture.oldWorktree, SweepFixture.recentWorktree, "bogus"]
        let ok = await vm.applySweepCleanup(projectID: workbenchID, ticked: ticked)

        XCTAssertTrue(ok)
        XCTAssertEqual(applyCalls(runner), [[
            "workbench", "cleanup", "--workbench=2", "--sweep", "--live-session=3", "--live-session=7",
            "--apply", "--item=\(SweepFixture.oldWorktree)", "--json"
        ]])
        guard case let .done(result) = cleanup.cleanupPhase(for: .workbench(workbenchID)) else {
            return XCTFail("the open sheet shows the result")
        }
        XCTAssertEqual(result.summary, "1 worktree removed (~2.0 GB)")
        vm.closeSweepSheet(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "closing the sheet forgets it")
    }

    func testSweepNeverAppliesUnknownKinds() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan), .success(SweepFixture.applied)])
        let (vm, cleanup) = makeVM(runner)
        await vm.planSweepForSheet(projectID: workbenchID)
        XCTAssertFalse(try readyPlan(cleanup).knownRemovableKeys.contains("gizmo:1"))

        let onlyUnknown = await vm.applySweepCleanup(projectID: workbenchID, ticked: ["gizmo:1"])
        XCTAssertFalse(onlyUnknown)
        XCTAssertEqual(applyCalls(runner), [], "an unknown kind alone runs nothing")

        await vm.applySweepCleanup(projectID: workbenchID, ticked: ["gizmo:1", SweepFixture.oldBranch])
        XCTAssertEqual(applyCalls(runner).first?.filter { $0.hasPrefix("--item") }, ["--item=\(SweepFixture.oldBranch)"])
    }

    // MARK: - Leaving the page

    /// The sheet's task starts the plan, the page goes away: the plan runs
    /// on; then an apply goes on after the sheet closed and is forgotten
    /// once it ended.
    func testSweepSurvivesLeavingThePage() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan), .success(SweepFixture.applied)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        vm.sweepSheetAppeared(projectID: workbenchID)

        let sheetTask = Task { await vm.planSweepForSheet(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        sheetTask.cancel()
        runner.release()
        await sheetTask.value
        XCTAssertEqual(runner.cancelledCount, 0, "the plan's CLI was not stopped")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)

        let apply = Task { await vm.applySweepCleanup(projectID: workbenchID, ticked: [SweepFixture.oldWorktree]) }
        while runner.heldCount == 0 { await Task.yield() }
        apply.cancel()
        vm.closeSweepSheet(projectID: workbenchID)
        vm.sweepSheetDisappeared(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .applying, "the apply goes on")
        runner.release()
        let ok = await apply.value

        XCTAssertTrue(ok)
        XCTAssertEqual(runner.cancelledCount, 0, "the apply's CLI was not stopped")
        XCTAssertEqual(applyCalls(runner).count, 1)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "forgotten once it ended")
        XCTAssertNil(vm.sessionErrors[workbenchID])
    }

    func testSweepFailureAfterTheSheetClosedShowsOnThePage() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(SweepFixture.plan), .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "git missing"))
        ])
        let (vm, cleanup) = makeVM(runner)
        vm.sweepSheetAppeared(projectID: workbenchID)
        await vm.planSweepForSheet(projectID: workbenchID)

        runner.holdsCalls = true
        let apply = Task { await vm.applySweepCleanup(projectID: workbenchID, ticked: [SweepFixture.oldWorktree]) }
        while runner.heldCount == 0 { await Task.yield() }
        vm.closeSweepSheet(projectID: workbenchID)
        vm.sweepSheetDisappeared(projectID: workbenchID)
        runner.release()
        let ok = await apply.value

        XCTAssertFalse(ok)
        let error = try XCTUnwrap(vm.sessionErrors[workbenchID])
        XCTAssertTrue(error.contains("Cleanup of old worktrees failed") && error.contains("git missing"), error)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle)
    }

    // MARK: - One-time hint

    func testSweepHintShownOnceAboveOneGigabyte() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner, live: [3])

        await vm.checkCleanupHint(projectID: workbenchID)
        XCTAssertEqual(vm.cleanupHints[workbenchID], "Old worktrees use ~2.0 GB.",
                       "only the removable worktree counts, not the kept 5 GB")
        XCTAssertEqual(runner.calls.first?.args,
                       ["workbench", "cleanup", "--workbench=2", "--sweep", "--live-session=3", "--json"])
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "the hint's plan is not kept")

        await vm.checkCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 1, "one sweep per launch")

        vm.cleanupHintShown(projectID: workbenchID)
        XCTAssertTrue(defaults.bool(forKey: "projects.cleanupHintShown.\(workbenchID)"))
        vm.dismissCleanupHint(projectID: workbenchID)
        XCTAssertNil(vm.cleanupHints[workbenchID])

        // The next launch: shown before, so never planned for again.
        let (next, _) = makeVM(runner)
        await next.checkCleanupHint(projectID: workbenchID)
        XCTAssertNil(next.cleanupHints[workbenchID])
        XCTAssertEqual(runner.calls.count, 1, "no sweep once the hint was shown")
    }

    func testSweepHintStaysAwayAtOrBelowOneGigabyte() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.smallPlan)])
        let (vm, _) = makeVM(runner)

        await vm.checkCleanupHint(projectID: workbenchID)

        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertFalse(defaults.bool(forKey: WorkbenchesViewModel.cleanupHintShownKey(workbenchID)),
                       "never shown, so a later launch may still find more")
        XCTAssertNil(SessionCleanupPresentation.sweepHint(SessionCleanupPlan(items: [
            SessionCleanupItem(key: "worktree:x", kind: .worktree, bytes: 1_000_000_000, bytesKnown: true, action: .remove)
        ])), "exactly 1 GB is not over it")
    }

    /// Opening the sweep answers the hint: it goes and never comes back.
    func testOpeningTheSweepAnswersTheHint() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        await vm.checkCleanupHint(projectID: workbenchID)
        XCTAssertNotNil(vm.cleanupHints[workbenchID])

        vm.sweepSheetAppeared(projectID: workbenchID)
        await vm.planSweepForSheet(projectID: workbenchID)

        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertTrue(defaults.bool(forKey: WorkbenchesViewModel.cleanupHintShownKey(workbenchID)))
    }

    /// The sheet open, no hint sweep runs over it.
    func testNoHintSweepWhileTheSheetIsOpen() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        vm.sweepSheetAppeared(projectID: workbenchID)

        await vm.checkCleanupHint(projectID: workbenchID)

        XCTAssertEqual(runner.calls.count, 0)
        XCTAssertNil(vm.cleanupHints[workbenchID])
    }
}
