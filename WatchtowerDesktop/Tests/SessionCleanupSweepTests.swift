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
        // The page has been on screen long enough unless a test holds it.
        vm.cleanupHintSleep = { _ in }
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

        // The sweep sheet's rule, whatever the JSON's flag says.
        var flagless = plan
        flagless.sweep = false
        let ticks = flagless.initialTicks(sweep: true)
        XCTAssertEqual(ticks, [], "a sweep arrives with nothing ticked")
        XCTAssertEqual(vm.sweepCleanupChoice(projectID: workbenchID, ticked: ticks), [])
        let ok = await vm.applySweepCleanup(projectID: workbenchID, ticked: ticks)
        XCTAssertFalse(ok)
        XCTAssertEqual(applyCalls(runner), [], "with nothing ticked nothing runs")

        // The session sheet still ticks every removable item of a known kind.
        let sessionPlan = try JSONDecoder().decode(SessionCleanupPlan.self, from: CleanupFixture.plan)
        XCTAssertEqual(sessionPlan.initialTicks(sweep: false), Set(CleanupFixture.plannedKeys))
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

        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(vm.cleanupHints[workbenchID], "Old worktrees use ~2.0 GB.",
                       "only the removable worktree counts, not the kept 5 GB")
        XCTAssertTrue(defaults.bool(forKey: "projects.cleanupHintShown.\(workbenchID)"),
                      "the key is written as the hint goes up on the page")
        XCTAssertEqual(runner.calls.first?.args,
                       ["workbench", "cleanup", "--workbench=2", "--sweep", "--live-session=3", "--json"])
        XCTAssertEqual(try? readyPlan(cleanup).items.count, 4, "the hint's plan is kept for the sheet")

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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.smallPlan)])
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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.smallPlan)])
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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.unmeasuredPlan)])
        let (vm, _) = makeVM(runner)

        await vm.watchCleanupHint(projectID: workbenchID)

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertNil(defaults.object(forKey: WorkbenchesViewModel.cleanupHintCheckedAtKey(workbenchID)))
    }

    /// A check stamp in the future (the clock was set back since) is due.
    func testFutureCheckStampIsDue() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.smallPlan)])
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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        await cleanup.planSweep(workbenchID: workbenchID)
        guard case .ready = cleanup.cleanupPhase(for: .workbench(workbenchID)) else { return XCTFail("no plan") }

        vm.finishCleanupHint(projectID: workbenchID, center: cleanup, pageLeft: true)

        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle, "the landed plan is forgotten")
        XCTAssertNil(vm.cleanupHints[workbenchID])
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertNotNil(vm.cleanupHints[workbenchID], "the next visit hints")
    }

    /// A stalled hint plan is stopped at its time limit and frees the slot.
    func testHintPlanStopsAtItsTimeLimit() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
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
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
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

    /// The sweep sheet opened while the hint plan runs: the sheet's plan
    /// stays, and no hint goes up behind it.
    func testSheetOpenedMidHintKeepsTheSheetsPlan() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)

        let page = Task { await vm.watchCleanupHint(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        vm.sweepSheetAppeared(projectID: workbenchID)
        let sheet = Task { await vm.planSweepForSheet(projectID: workbenchID) }
        while runner.heldCount < 2 { await Task.yield() }
        runner.release()
        await page.value
        await sheet.value

        XCTAssertEqual(try readyPlan(cleanup).items.count, 4, "the sheet's plan is kept")
        XCTAssertNil(vm.cleanupHints[workbenchID])
    }

    /// Opening the sweep answers the hint: it goes and never comes back.
    func testOpeningTheSweepAnswersTheHint() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertNotNil(vm.cleanupHints[workbenchID])

        vm.sweepSheetAppeared(projectID: workbenchID)
        await vm.planSweepForSheet(projectID: workbenchID)

        XCTAssertNil(vm.cleanupHints[workbenchID])
        XCTAssertTrue(defaults.bool(forKey: WorkbenchesViewModel.cleanupHintShownKey(workbenchID)))
    }

    /// The hint's **Review**: the sheet shows the plan the hint already
    /// made instead of walking every worktree again (board #704).
    func testSheetOpenedFromTheHintReusesItsPlan() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        await vm.watchCleanupHint(projectID: workbenchID)

        vm.sweepSheetAppeared(projectID: workbenchID)
        await vm.planSweepForSheet(projectID: workbenchID)

        XCTAssertEqual(runner.calls.count, 1, "no second plan")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)
    }

    /// Closing the sheet while it plans leaves the plan running; reopening
    /// waits for that plan instead of starting over (board #704).
    func testClosingTheSheetMidPlanKeepsThePlanForTheNextOpen() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        vm.sweepSheetAppeared(projectID: workbenchID)
        let first = Task { await vm.planSweepForSheet(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        first.cancel()
        vm.closeSweepSheet(projectID: workbenchID)
        vm.sweepSheetDisappeared(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .planning, "the plan goes on")

        vm.sweepSheetAppeared(projectID: workbenchID)
        var secondEnded = false
        let second = Task {
            await vm.planSweepForSheet(projectID: workbenchID)
            secondEnded = true
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(secondEnded, "the reopened sheet waits for the running plan")
        runner.release()
        await second.value

        XCTAssertEqual(runner.calls.count, 1, "the reopened sheet waits for the running plan")
        XCTAssertEqual(runner.cancelledCount, 0)
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)

        // A ready plan is forgotten on close: the next open plans afresh.
        vm.closeSweepSheet(projectID: workbenchID)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(workbenchID)), .idle)
    }

    /// A sheet's plan stalled on a read is stopped at its time limit and
    /// shows a failure, closed and reopened or not (board #704).
    func testStalledSheetPlanFailsAtItsTimeLimit() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        runner.holdsCalls = true
        let (vm, cleanup) = makeVM(runner)
        vm.cleanupHintTimeLimit = .milliseconds(50)
        vm.sweepSheetAppeared(projectID: workbenchID)
        let first = Task { await vm.planSweepForSheet(projectID: workbenchID) }
        while runner.heldCount == 0 { await Task.yield() }
        first.cancel()
        vm.closeSweepSheet(projectID: workbenchID)
        vm.sweepSheetDisappeared(projectID: workbenchID)

        vm.sweepSheetAppeared(projectID: workbenchID)
        let reopened = Task { await vm.planSweepForSheet(projectID: workbenchID) }
        try await Task.sleep(for: .milliseconds(150))
        runner.release() // the real runner ends the child on cancel
        await reopened.value

        guard case let .failed(message) = cleanup.cleanupPhase(for: .workbench(workbenchID)) else {
            return XCTFail("expected the stopped plan to fail, got \(cleanup.cleanupPhase(for: .workbench(workbenchID)))")
        }
        XCTAssertTrue(message.contains("was stopped"), message)
        XCTAssertEqual(runner.cancelledCount, 1)
        XCTAssertEqual(runner.calls.count, 1, "the reopened sheet waited for the same plan")
    }

    /// A ready plan older than the reuse window is planned again.
    func testOldReadyPlanIsPlannedAgain() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan), .success(SweepFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        var clock = Date(timeIntervalSince1970: 1_000_000)
        cleanup.now = { clock }
        await vm.watchCleanupHint(projectID: workbenchID)
        clock += WorkbenchesViewModel.sweepPlanReuseWindow + 1

        vm.sweepSheetAppeared(projectID: workbenchID)
        await vm.planSweepForSheet(projectID: workbenchID)

        XCTAssertEqual(runner.calls.count, 2, "a stale hint plan is not shown")
        XCTAssertEqual(try readyPlan(cleanup).items.count, 4)
    }

    /// Opening the sweep before the hint plan ever ran answers it too.
    func testNoHintSweepOnceTheSheetWasOpened() async {
        let runner = FakeSessionCleanupRunner(replies: [.success(SweepFixture.plan)])
        let (vm, _) = makeVM(runner)
        vm.sweepSheetAppeared(projectID: workbenchID)

        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 0, "not while the sheet is open")

        await vm.planSweepForSheet(projectID: workbenchID)
        vm.closeSweepSheet(projectID: workbenchID)
        await vm.watchCleanupHint(projectID: workbenchID)
        XCTAssertEqual(runner.calls.count, 1, "only the sheet's plan ran")
        XCTAssertNil(vm.cleanupHints[workbenchID])
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
