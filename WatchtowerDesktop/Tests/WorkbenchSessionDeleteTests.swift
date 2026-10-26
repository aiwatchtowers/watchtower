import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Undo window's wait, held for the whole test (opened in tearDown).
@MainActor
private final class HeldWindow {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait(_: Duration) async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        let resumed = waiting
        waiting = []
        resumed.forEach { $0.resume() }
    }
}

/// Delete Session with cleanup (board #535, spec 2026-10-12-session-cleanup
/// §12, PROJ-18) composed with the deferred delete (PROJ-17), and the
/// report's Cleanup line. No subprocess is spawned: terminals are fake and
/// the cleanup runner is a double.
@MainActor
final class WorkbenchSessionDeleteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var terminals: TerminalCenter!
    private var window: HeldWindow!
    private var streamers: [RepliedCleanupStreamer] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchSessionDeleteTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt cleanup \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("acme"), withIntermediateDirectories: true)
        terminals = TerminalCenter { FakeTerminalSession(pid: 0) }
        terminals.shell = { "/bin/zsh" }
        terminals.transcriptExists = { _ in true }
        window = HeldWindow()
    }

    override func tearDown() {
        streamers.forEach { $0.finishAll() }
        streamers = []
        window.open()
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    /// `streamer` runs the Clean Up screen's streamed plans and applies;
    /// `runner` the Delete dialog's.
    private func makeVM(
        _ runner: FakeSessionCleanupRunner, streamer: RepliedCleanupStreamer? = nil
    ) -> (WorkbenchesViewModel, SessionCleanupCenter) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: terminals)
        vm.titleService = { _ in .init(title: "", written: false) }
        vm.deleteSleep = { [window] in await window?.wait($0) }
        streamer.map { streamers.append($0) }
        let cleanup = SessionCleanupCenter(runner: runner, streamer: streamer)
        cleanup.liveSessionIDs = { [terminals] in terminals?.liveIDs ?? [] }
        vm.sessionCleanup = cleanup
        return (vm, cleanup)
    }

    /// A workbench with one running session on screen.
    private func liveSession(_ vm: WorkbenchesViewModel) async throws -> (Int64, TerminalSession) {
        let acme = folder.appendingPathComponent("acme").path
        let p = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: acme) }
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.newSession(projectID: p)
        let row = try XCTUnwrap(vm.sessions.first)
        XCTAssertTrue(terminals.liveIDs.contains(row.id))
        return (p, row)
    }

    private func stored(_ id: Int64) async throws -> TerminalSession? {
        try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
    }

    private func applyCalls(_ runner: FakeSessionCleanupRunner) -> [[String]] {
        runner.calls.map(\.args).filter { $0.contains("--apply") }
    }

    private func applyCalls(_ streamer: RepliedCleanupStreamer) -> [[String]] {
        streamer.calls.map(\.args).filter { $0.contains("--apply") }
    }

    /// Opens the Clean Up screen on `row`'s scope and waits for its plan.
    private func openScreen(_ vm: WorkbenchesViewModel, on row: TerminalSession) async throws {
        await vm.openCleanupScreen(projectID: try XCTUnwrap(row.projectID), sessionID: row.id).value
    }

    private func tick(_ vm: WorkbenchesViewModel, _ row: TerminalSession, _ ticks: Set<String>) {
        row.projectID.map { vm.cleanupScreens[$0]?.ticks = ticks }
    }

    /// Holds until `runner` holds a call.
    private func waitForHeldCall(_ runner: FakeSessionCleanupRunner) async {
        while runner.heldCount == 0 { await Task.yield() }
    }

    // MARK: - PROJ-18 guards

    func testProj18_DeleteAppliesOnlyThePlannedItems() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, cleanup) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let choice = try XCTUnwrap(vm.deleteCleanupChoice(row))
        XCTAssertEqual(choice.shownKeys, CleanupFixture.plannedKeys, "the kept worktree is not offered")
        let ok = await vm.deleteAndCleanUp(row, choice: choice)

        XCTAssertTrue(ok)
        let apply = try XCTUnwrap(applyCalls(runner).first)
        XCTAssertEqual(applyCalls(runner).count, 1)
        XCTAssertEqual(apply.filter { $0.hasPrefix("--item") }, choice.shownKeys.map { "--item=\($0)" },
                       "--apply names exactly the planned keys")
        XCTAssertTrue(apply.contains("--session=\(row.id)"))
        XCTAssertFalse(apply.contains("--live-session=\(row.id)"), "the terminal closed before the apply")
        XCTAssertFalse(terminals.liveIDs.contains(row.id))
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id), "then the normal deferred delete, with Undo")
        XCTAssertFalse(vm.sessions.contains { $0.id == row.id })
        XCTAssertNil(vm.sessionErrors[p], "nothing shown was kept: no notice")
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(row.id)), .idle, "a finished delete leaves no phase")
        XCTAssertFalse(vm.cleaningUpSessions.contains(row.id))
    }

    func testProj18_FailedCleanupKeepsTheSessionRow() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.plan),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "could not plan: git missing"))
        ])
        let (vm, cleanup) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, choice: vm.deleteCleanupChoice(row))

        XCTAssertFalse(ok)
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "the row is never deleted after a failed cleanup")
        XCTAssertFalse(vm.pendingDeletes.ids.contains(row.id), "not even into the Undo batch")
        XCTAssertTrue(vm.sessions.contains { $0.id == row.id }, "still listed")
        let error = try XCTUnwrap(vm.sessionErrors[p])
        XCTAssertTrue(error.contains("Cleanup failed") && error.contains("git missing"), error)
        XCTAssertNotNil(cleanup.failureText(for: .session(row.id)))
        XCTAssertFalse(vm.cleaningUpSessions.contains(row.id), "the row is no longer busy")
    }

    func testFailedItemKeepsTheSessionRow() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.plan), .success(CleanupFixture.appliedWithError)
        ])
        let (vm, _) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, choice: vm.deleteCleanupChoice(row))

        XCTAssertFalse(ok)
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
        XCTAssertFalse(vm.pendingDeletes.ids.contains(row.id))
        XCTAssertTrue(vm.sessionErrors[p]?.contains("feat/x: cannot lock ref") == true, vm.sessionErrors[p] ?? "")
    }

    func testDeleteOnlySkipsTheCleanup() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        let (vm, cleanup) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        // Delete Only: the dialog drops the plan and runs the plain delete.
        vm.dismissDeleteCleanup(row)
        await vm.delete(row)

        XCTAssertTrue(applyCalls(runner).isEmpty, "Delete Only never applies")
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(row.id)), .idle)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
    }

    /// The ✕ / ⌘⌫ path deletes without applying, even with a ready plan
    /// whose keys it could pass.
    func testQuickDeleteNeverCleansUp() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, _) = makeVM(runner)
        let acme = folder.appendingPathComponent("acme").path
        let p = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: acme) }
        let row = try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: p, kind: .claude, title: "Idle", targetID: nil, folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)
        await vm.planCleanupBeforeDelete(row)
        XCTAssertNotNil(vm.deleteCleanupChoice(row), "a plan is ready")

        let intent = await vm.deleteQuicklyOrConfirm(row)

        XCTAssertEqual(intent, .quick)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id), "deleted at once")
        XCTAssertTrue(applyCalls(runner).isEmpty, "the ✕ / ⌘⌫ path is Delete Only")
    }

    func testDeleteAndCleanUpWithNothingPlannedIsAPlainDelete() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.emptyPlan)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, choice: vm.deleteCleanupChoice(row))

        XCTAssertTrue(ok)
        XCTAssertTrue(applyCalls(runner).isEmpty)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
    }

    // MARK: - Shown items only (F3, F5)

    func testUnknownKindsAreNeverApplied() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.planWithUnknownKind), .success(CleanupFixture.applied)
        ])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let choice = try XCTUnwrap(vm.deleteCleanupChoice(row))
        XCTAssertEqual(choice.shownKeys, ["branch:feat/x"], "the dialog shows only kinds it knows")
        await vm.deleteAndCleanUp(row, choice: choice)

        XCTAssertEqual(applyCalls(runner).first?.filter { $0.hasPrefix("--item") }, ["--item=branch:feat/x"])
    }

    func testOnlyUnknownKindsMeanDeleteOnly() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.planUnknownOnly)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let choice = try XCTUnwrap(vm.deleteCleanupChoice(row))
        XCTAssertFalse(choice.offersCleanup, "no cleanup offer: the default is a plain delete")
        let ok = await vm.deleteAndCleanUp(row, choice: choice)

        XCTAssertTrue(ok)
        XCTAssertTrue(applyCalls(runner).isEmpty)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
    }

    /// The dialog planned while the session's terminal ran, so its own
    /// worktree was kept for a running process: shown as removed once the
    /// terminal closes, it is re-planned after the close and applied — and
    /// a key the dialog did not show is not, though now removable.
    func testWorktreeKeptByTheClosingTerminalIsRemoved() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.planBusy), .success(CleanupFixture.replanFree), .success(CleanupFixture.applied)
        ])
        let (vm, _) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let choice = try XCTUnwrap(vm.deleteCleanupChoice(row))
        let shown = ["worktree:/tmp/example/.claude/worktrees/x", "branch:feat/x"]
        XCTAssertEqual(choice.shownKeys, shown)
        let ok = await vm.deleteAndCleanUp(row, choice: choice)

        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.count, 3)
        let replan = runner.calls[1].args
        XCTAssertFalse(replan.contains("--apply"), "a fresh plan after the close")
        XCTAssertFalse(replan.contains("--live-session=\(row.id)"))
        XCTAssertEqual(applyCalls(runner).first?.filter { $0.hasPrefix("--item") }, shown.map { "--item=\($0)" },
                       "feat/old was never shown as removable: never applied")
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
        XCTAssertNil(vm.sessionErrors[p])
        XCTAssertNil(vm.pendingCleanupNotice, "nothing shown was kept")
    }

    /// Something else still runs in the worktree after the close: nothing
    /// is applied, the row is deleted and the page says what was kept.
    func testWorktreeStillBusyAfterTheCloseIsKept() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.planBusy)])
        let (vm, _) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, choice: vm.deleteCleanupChoice(row))

        XCTAssertTrue(ok)
        XCTAssertTrue(applyCalls(runner).isEmpty)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
        XCTAssertNil(vm.sessionErrors[p], "information, not an error")
        XCTAssertEqual(vm.pendingCleanupNotice,
                       "“\(row.title)” deleted; 2 items were kept: x — a process is running in it; feat/x — checked out")
    }

    // MARK: - After the apply (F4, F7)

    func testDeleteAndCleanUpTellsWhatGoKept() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.plan), .success(CleanupFixture.appliedKeptBranch)
        ])
        let (vm, _) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, choice: vm.deleteCleanupChoice(row))

        XCTAssertTrue(ok, "a kept item is not a failure")
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
        XCTAssertNil(vm.sessionErrors[p], "a successful delete is not an error line")
        XCTAssertEqual(vm.pendingCleanupNotice, "“\(row.title)” deleted; 1 item was kept: feat/x — unpushed commits",
                       "told on the Undo bar")

        await vm.undoPendingDeletes()
        XCTAssertNil(vm.pendingCleanupNotice, "Undo brings the row back: no “deleted” line stays")
        XCTAssertTrue(vm.cleanupKeptNotices.isEmpty)
    }

    func testBusyRowRefusesDeleteAndResume() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)
        await vm.planCleanupBeforeDelete(row)
        let choice = vm.deleteCleanupChoice(row)

        runner.holdsCalls = true
        let run = vm.startDeleteAndCleanUp(row, choice: choice)
        await waitForHeldCall(runner)
        XCTAssertTrue(vm.cleaningUpSessions.contains(row.id))

        let intent = await vm.deleteQuicklyOrConfirm(row)
        XCTAssertEqual(intent, .busy, "✕ / ⌘⌫ do nothing")
        await vm.delete(row)
        XCTAssertFalse(vm.pendingDeletes.ids.contains(row.id), "no delete while the apply runs")
        await vm.open(row)
        XCTAssertFalse(terminals.liveIDs.contains(row.id), "no resume while the apply runs")
        let second = await vm.startDeleteAndCleanUp(row, choice: choice).value
        XCTAssertFalse(second)

        runner.release()
        let ok = await run.value
        XCTAssertTrue(ok)
        XCTAssertEqual(applyCalls(runner).count, 1)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
        XCTAssertFalse(vm.cleaningUpSessions.contains(row.id))
    }

    /// Work on It (and the phone's open_existing) on the session's target
    /// while its Delete and Clean Up runs: no resume, no new row.
    func testWorkOnDuringTheCleanupDoesNotResume() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, _) = makeVM(runner)
        let acme = folder.appendingPathComponent("acme").path
        let p = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: acme) }
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Ship it") }
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.workOn(targetID: target, targetText: "Ship it", projectID: p)
        let row = try XCTUnwrap(vm.terminalSessions[p]?.first { $0.targetID == target })
        XCTAssertTrue(terminals.liveIDs.contains(row.id))
        await vm.planCleanupBeforeDelete(row)

        runner.holdsCalls = true
        let run = vm.startDeleteAndCleanUp(row, choice: vm.deleteCleanupChoice(row))
        await waitForHeldCall(runner)
        await vm.workOn(targetID: target, targetText: "Ship it", projectID: p)
        await vm.startFresh(row)
        do {
            _ = try await vm.startForTarget(targetID: target, prompt: nil, mode: .openExisting, placement: .background)
            XCTFail("the phone's open_existing must be refused")
        } catch let error as WorkbenchesViewModel.TargetStartError {
            XCTAssertEqual(error, .cleaningUp, "refused as a cleanup, not as a start in flight")
            XCTAssertEqual(SessionStartStopHandlers.outcome(error),
                           .failed(.conflict, message: "This session is being cleaned up on the Mac"))
        }

        XCTAssertFalse(terminals.liveIDs.contains(row.id), "the closed agent is not resumed")
        let rows = try await pool.read { try TerminalSessionQueries.fetchForTarget($0, targetID: target) }
        XCTAssertEqual(rows.map(\.id), [row.id], "and no new session starts")
        runner.release()
        let ok = await run.value
        XCTAssertTrue(ok)
    }

    /// The Clean Up screen's apply in a session's scope makes the row busy
    /// for deleting, but its terminal stays reachable: the row still opens
    /// and resumes.
    func testSheetApplyMarksTheRowBusy() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, _) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)
        await terminals.close(sessionID: row.id)
        XCTAssertFalse(terminals.liveIDs.contains(row.id))
        try await openScreen(vm, on: row)
        tick(vm, row, Set(CleanupFixture.plannedKeys))

        streamer.holdsCalls = true
        let apply = Task { await vm.applyCleanupScreen(projectID: p) }
        while streamer.heldCount == 0 { await Task.yield() }
        XCTAssertTrue(vm.cleaningUpSessions.contains(row.id))
        let intent = await vm.deleteQuicklyOrConfirm(row)
        XCTAssertEqual(intent, .busy)
        await vm.delete(row)
        XCTAssertFalse(vm.pendingDeletes.ids.contains(row.id), "no delete while the apply runs")
        let deleteAndCleanUp = await vm.startDeleteAndCleanUp(row, choice: nil).value
        XCTAssertFalse(deleteAndCleanUp, "no Delete and Clean Up either")
        await vm.open(row)
        XCTAssertTrue(terminals.liveIDs.contains(row.id), "the session still resumes during a Clean Up… apply")

        streamer.release()
        let ok = await apply.value
        XCTAssertTrue(ok)
        XCTAssertFalse(vm.cleaningUpSessions.contains(row.id), "free again once it ended")
        XCTAssertEqual(applyCalls(streamer).count, 1)
    }

    /// An item of a kind this version does not know is listed on the screen
    /// but never ticked or applied, as in the Delete dialog.
    func testSheetNeverAppliesUnknownKinds() async throws {
        let streamer = RepliedCleanupStreamer(replies: [
            .success(CleanupFixture.planWithUnknownKind), .success(CleanupFixture.applied)
        ])
        let (vm, cleanup) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)
        try await openScreen(vm, on: row)
        guard case let .ready(plan) = cleanup.cleanupPhase(for: .session(row.id)) else { return XCTFail("no plan") }
        XCTAssertEqual(plan.knownRemovableKeys, ["branch:feat/x"], "what the screen offers")

        let ticked: Set = ["gizmo:1", "branch:feat/x"]
        XCTAssertEqual(vm.cleanupScreenModel(projectID: p)?.applyKeys(for: ticked), ["branch:feat/x"])
        tick(vm, row, ticked)
        await vm.applyCleanupScreen(projectID: p)

        XCTAssertEqual(applyCalls(streamer).first?.filter { $0.hasPrefix("--item") }, ["--item=branch:feat/x"])
    }

    /// While the screen's apply runs, Delete and Clean Up waits ("Another
    /// cleanup is running") and launches nothing; Delete Only still works.
    func testDeleteAndCleanUpWaitsForTheScreensApply() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, _) = makeVM(runner, streamer: streamer)
        let (p, row) = try await liveSession(vm)
        await vm.planCleanupBeforeDelete(row)
        let choice = try XCTUnwrap(vm.deleteCleanupChoice(row))
        XCTAssertFalse(vm.deleteAndCleanUpBlocked(projectID: p))

        await vm.openCleanupScreen(projectID: p).value
        vm.cleanupScreens[p]?.ticks = ["worktree:/tmp/example/.claude/worktrees/x"]
        streamer.holdsCalls = true
        let apply = Task { await vm.applyCleanupScreen(projectID: p) }
        while streamer.heldCount == 0 { await Task.yield() }

        XCTAssertTrue(vm.deleteAndCleanUpBlocked(projectID: p))
        let refused = await vm.startDeleteAndCleanUp(row, choice: choice).value
        XCTAssertFalse(refused)
        XCTAssertEqual(applyCalls(runner), [], "Delete and Clean Up launched nothing")
        XCTAssertFalse(vm.cleaningUpSessions.contains(row.id))
        XCTAssertTrue(terminals.liveIDs.contains(row.id), "its terminal was not closed for a cleanup that cannot run")
        XCTAssertNil(vm.sessionErrors[p], "a refusal, not a failed cleanup")
        await vm.delete(row)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id), "Delete Only still works")

        streamer.release()
        _ = await apply.value
        XCTAssertFalse(vm.deleteAndCleanUpBlocked(projectID: p), "free again once it ended")
    }

    // MARK: - Leaving the page (F1)

    /// The Delete dialog's task starts the plan, then the owner leaves the
    /// page: the task is cancelled, the plan runs on and is ready on return.
    func testPlanSurvivesLeavingThePage() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        runner.holdsCalls = true
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        let sheetTask = Task { await vm.planCleanupBeforeDelete(row) }
        await waitForHeldCall(runner)
        sheetTask.cancel()
        XCTAssertEqual(vm.deleteCleanupPhase(row), .planning)

        runner.release()
        await sheetTask.value

        XCTAssertEqual(runner.cancelledCount, 0, "the CLI was not stopped")
        XCTAssertEqual(vm.deleteCleanupChoice(row)?.shownKeys, CleanupFixture.plannedKeys,
                       "the plan is ready, not failed")
    }

    /// Delete and Clean Up started from the dialog goes on when the caller
    /// is cancelled: the apply finishes and the row is deleted.
    func testDeleteAndCleanUpSurvivesLeavingThePage() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, cleanup) = makeVM(runner)
        let (_, row) = try await liveSession(vm)
        await vm.planCleanupBeforeDelete(row)
        let choice = vm.deleteCleanupChoice(row)

        runner.holdsCalls = true
        let caller = Task { await vm.deleteAndCleanUp(row, choice: choice) }
        await waitForHeldCall(runner)
        caller.cancel()
        runner.release()
        let ok = await caller.value

        XCTAssertTrue(ok)
        XCTAssertEqual(runner.cancelledCount, 0, "the apply was not stopped")
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(row.id)), .idle)
    }

    // MARK: - Clean Up screen, a session's scope (F6, F8, F11)

    func testSessionScopeAppliesOnlyTheTickedRowsThenReloadsTheReport() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, cleanup) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)
        let (store, id) = (try XCTUnwrap(pool), row.id)
        let stored = String(bytes: CleanupFixture.applied, encoding: .utf8)
        // Go stores the apply's result as it runs; the plan comes first.
        try await openScreen(vm, on: row)
        try await store.write { db in
            try db.execute(
                sql: "UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = ? WHERE id = ?",
                arguments: [stored, "2026-10-12T10:00:00Z", id]
            )
        }
        // The worktree row goes with its removable branch (PROJ-18,
        // 2026-10-26 amendment); a kept item and a stray key cannot be
        // applied whatever the ticks say.
        let ticked: Set = ["worktree:/tmp/example/.claude/worktrees/x", "worktree:/tmp/example/.claude/worktrees/y", "bogus"]
        tick(vm, row, ticked)
        let ok = await vm.applyCleanupScreen(projectID: p)

        XCTAssertTrue(ok)
        XCTAssertEqual(applyCalls(streamer).first?.filter { $0.hasPrefix("--item") },
                       ["--item=worktree:/tmp/example/.claude/worktrees/x", "--item=branch:feat/x"])
        XCTAssertEqual(vm.cleanupReportLine(sessionID: row.id), "1 worktree, 1 branch removed (~2.0 GB)",
                       "the report's Cleanup line reloaded")
        guard case .done = cleanup.cleanupPhase(for: .session(row.id)) else {
            return XCTFail("the open screen shows the result")
        }
        vm.closeCleanupScreen(projectID: p)
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(row.id)), .idle, "closing the screen forgets it")
    }

    /// A failed apply the screen shows on its scope stays on the screen; one
    /// that ends after the screen closed (or shows another scope) goes on
    /// the page and is forgotten — in a session's scope and the workbench's.
    func testApplyFailureShowsOnTheScreenWhenOpenElseOnThePage() async throws {
        let failure = Result<Data, Error>.failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "git missing"))
        let streamer = RepliedCleanupStreamer(replies: [
            .success(CleanupFixture.plan), failure,
            .success(CleanupFixture.plan), failure,
            .success(CleanupFixture.plan), failure
        ])
        let (vm, cleanup) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)
        let worktree: Set = ["worktree:/tmp/example/.claude/worktrees/x"]

        // Open on the session's scope: the screen shows it.
        try await openScreen(vm, on: row)
        tick(vm, row, worktree)
        let shown = await vm.applyCleanupScreen(projectID: p)
        XCTAssertFalse(shown)
        XCTAssertNil(vm.sessionErrors[p], "the screen shows it")
        guard case .failed = cleanup.cleanupPhase(for: .session(row.id)) else {
            return XCTFail("expected the failure kept for the screen")
        }
        vm.closeCleanupScreen(projectID: p)

        // Closed while the session's apply runs: on the page.
        try await openScreen(vm, on: row)
        tick(vm, row, worktree)
        streamer.holdsCalls = true
        let apply = Task { await vm.applyCleanupScreen(projectID: p) }
        while streamer.heldCount == 0 { await Task.yield() }
        vm.closeCleanupScreen(projectID: p)
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(row.id)), .applying, "the apply goes on")
        streamer.holdsCalls = false
        streamer.release()
        let unseen = await apply.value
        XCTAssertFalse(unseen)
        var error = try XCTUnwrap(vm.sessionErrors[p])
        XCTAssertTrue(error.contains("Cleanup of “\(row.title)” failed") && error.contains("git missing"), error)
        XCTAssertEqual(cleanup.cleanupPhase(for: .session(row.id)), .idle, "forgotten once surfaced")

        // The workbench's scope, closed mid-apply: on the page too.
        vm.setSessionError(nil, projectID: p)
        await vm.openCleanupScreen(projectID: p).value
        vm.cleanupScreens[p]?.ticks = worktree
        streamer.holdsCalls = true
        let sweep = Task { await vm.applyCleanupScreen(projectID: p) }
        while streamer.heldCount == 0 { await Task.yield() }
        vm.closeCleanupScreen(projectID: p)
        streamer.release()
        let sweepOK = await sweep.value
        XCTAssertFalse(sweepOK)
        error = try XCTUnwrap(vm.sessionErrors[p])
        XCTAssertTrue(error.contains("Cleanup of old worktrees failed") && error.contains("git missing"), error)
        XCTAssertEqual(cleanup.cleanupPhase(for: .workbench(p)), .idle)
    }

    // MARK: - Report line

    func testReportShowsTheCleanupLine() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)
        let other = try await pool.write { db -> Int64 in
            try TerminalSessionQueries.create(db, .init(
                projectID: row.projectID, kind: .claude, title: "Other", targetID: nil, folderPath: row.folderPath,
                claudeSessionID: UUID().uuidString.lowercased()
            )).id
        }

        await vm.loadCleanupRecord(sessionID: row.id)
        XCTAssertNil(vm.cleanupReportLine(sessionID: row.id), "never cleaned up: no line")

        try await pool.write { db in
            try db.execute(
                sql: "UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = ? WHERE id = ?",
                arguments: [String(bytes: CleanupFixture.applied, encoding: .utf8), "2026-10-12T10:00:00Z", row.id]
            )
            try db.execute(
                sql: "UPDATE terminal_sessions SET cleanup_result = '{not json', cleanup_at = ? WHERE id = ?",
                arguments: ["2026-10-12T10:00:00Z", other]
            )
        }
        await vm.loadCleanupRecord(sessionID: row.id)
        await vm.loadCleanupRecord(sessionID: other)

        XCTAssertEqual(vm.cleanupReportLine(sessionID: row.id), "1 worktree, 1 branch removed (~2.0 GB)")
        XCTAssertEqual(vm.cleanupRecords[row.id]?.at, "2026-10-12T10:00:00Z")
        XCTAssertEqual(vm.cleanupReportLine(sessionID: other), "Cleanup ran — result unreadable")
    }

    /// The section's observation follows the stored result: it first
    /// shows what is there, then a result written later (the agent's
    /// `finish_session` cleanup) — a one-time read would miss the second.
    func testReportWatchesTheStoredResult() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)
        try await storeCleanupResult(CleanupFixture.appliedWithError, at: "2026-10-12T09:00:00Z", sessionID: row.id)
        let watch = Task { await vm.observeCleanupRecord(sessionID: row.id) }
        defer { watch.cancel() }
        try await waitUntil { vm.cleanupRecords[row.id]?.at == "2026-10-12T09:00:00Z" }

        try await storeCleanupResult(CleanupFixture.applied, at: "2026-10-12T10:00:00Z", sessionID: row.id)
        try await waitUntil { vm.cleanupRecords[row.id]?.at == "2026-10-12T10:00:00Z" }

        XCTAssertEqual(vm.cleanupReportLine(sessionID: row.id), "1 worktree, 1 branch removed (~2.0 GB)")
        watch.cancel()
        await watch.value
    }

    private func storeCleanupResult(_ json: Data, at: String, sessionID: Int64) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = ? WHERE id = ?",
                arguments: [String(bytes: json, encoding: .utf8), at, sessionID]
            )
        }
    }

    /// Waits up to 2 s for `condition`; fails the test past that.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}
