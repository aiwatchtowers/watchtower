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

/// Every delete cleans up in the background once the Undo window ends
/// (board #1716, PROJ-17/18 amended, spec
/// 2026-11-10-auto-cleanup-on-session-delete), the Clean Up screen's apply
/// in a session's scope (board #535), and the report's Cleanup line. No
/// subprocess is spawned: terminals are fake and the cleanup runners are
/// doubles.
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

    /// `streamer` runs the Clean Up screen's streamed plans and applies and
    /// the background cleanups; `runner` the non-streamed runs.
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

    /// A workbench with one idle (not running) agent session listed.
    private func idleSession(_ vm: WorkbenchesViewModel) async throws -> (Int64, TerminalSession) {
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
        return (p, row)
    }

    private func deleteRequestedAt(_ id: Int64) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT delete_requested_at FROM terminal_sessions WHERE id = ?", arguments: [id])
        }
    }

    /// The Undo window ends and every background cleanup it queued ends.
    private func endWindow(_ vm: WorkbenchesViewModel) async {
        window.open()
        await vm.deleteCommitTask?.value
        await vm.autoCleanupIdle()
    }

    private func waitUntilHeld(_ streamer: RepliedCleanupStreamer, _ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while streamer.heldCount < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(streamer.heldCount, count, "the background apply never started")
    }

    // MARK: - PROJ-17 / PROJ-18 guards (board #1716, ask #1210)

    /// An idle row deleted with ✕ / ⌘⌫: nothing is written inside the
    /// window; when it ends the row is marked deleted and handed to the
    /// background cleanup, whose apply names no item; a clean result
    /// deletes the row.
    func testProj17_EveryDeleteCleansUpAfterTheWindow() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.applied)])
        streamer.holdsCalls = true
        let (vm, _) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await idleSession(vm)

        let intent = await vm.deleteQuicklyOrConfirm(row)
        XCTAssertEqual(intent, .quick)
        let before = try await deleteRequestedAt(row.id)
        XCTAssertNil(before, "nothing written inside the window")
        XCTAssertTrue(streamer.calls.isEmpty, "no cleanup inside the window")

        window.open()
        await vm.deleteCommitTask?.value
        await waitUntilHeld(streamer, 1)
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested, "marked when the window ended")
        XCTAssertEqual(vm.autoCleanupQueue[p], [row.id])
        XCTAssertFalse(vm.sessions.contains { $0.id == row.id })
        let apply = try XCTUnwrap(applyCalls(streamer).first)
        XCTAssertFalse(apply.contains { $0.hasPrefix("--item") })

        streamer.release()
        await vm.autoCleanupIdle()
        let gone = try await stored(row.id)
        XCTAssertNil(gone, "a clean outcome deletes the row")
        XCTAssertNil(vm.autoCleanupQueue[p])
        XCTAssertNil(vm.notFullyCleaned[row.id])
    }

    /// The background apply is `--apply` with no `--item`: Go re-plans and
    /// removes everything removable when it runs. The session's own closed
    /// terminal is never passed as live.
    func testProj18_BackgroundApplyHasNoItemFilter() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.applied)])
        let (vm, _) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)

        await vm.delete(row)
        await endWindow(vm)

        let apply = try XCTUnwrap(applyCalls(streamer).first)
        XCTAssertEqual(applyCalls(streamer).count, 1)
        XCTAssertEqual(apply.filter { $0.hasPrefix("--item") }, [], "never an item filter")
        XCTAssertTrue(apply.contains("--apply") && apply.contains("--json"))
        XCTAssertTrue(apply.contains("--session=\(row.id)") && apply.contains("--workbench=\(p)"))
        XCTAssertFalse(apply.contains("--live-session=\(row.id)"), "its terminal closed with the delete")
        XCTAssertNil(streamer.calls.first?.environment[SessionCleanupCenter.terminalSessionVariable])
    }

    /// A could-not result keeps the row, marked Not fully cleaned, in the
    /// finished group; it stays out of the lists.
    func testProj18_FailedCleanupKeepsTheSessionRow() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(AutoCleanupFixture.processRunning)])
        let (vm, _) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)

        await vm.delete(row)
        await endWindow(vm)

        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "the row is never deleted after a failed cleanup")
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested, "still deleting")
        XCTAssertEqual(vm.notFullyCleaned[row.id], "Not fully cleaned: 1 worktree — a process is running in it.")
        XCTAssertEqual(vm.notFullyCleanedRows[p]?.map(\.id), [row.id], "in the finished group")
        XCTAssertFalse(vm.sessions.contains { $0.id == row.id }, "in no list")
        XCTAssertNil(vm.autoCleanupQueue[p])
    }

    /// An item Go failed to remove (an error) is a could-not too.
    func testFailedItemKeepsTheSessionRow() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.appliedWithError)])
        let (vm, _) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (_, row) = try await liveSession(vm)

        await vm.delete(row)
        await endWindow(vm)

        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
        XCTAssertEqual(vm.notFullyCleaned[row.id], "Not fully cleaned: 1 branch — could not be removed.")
    }

    /// A run that failed as a whole (exit ≠ 0) is a could-not with the CLI's words.
    func testFailedRunKeepsTheSessionRow() async throws {
        let streamer = RepliedCleanupStreamer(replies: [
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "git missing"))
        ])
        let (vm, _) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (_, row) = try await liveSession(vm)

        await vm.delete(row)
        await endWindow(vm)

        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
        let mark = try XCTUnwrap(vm.notFullyCleaned[row.id])
        XCTAssertTrue(mark.hasPrefix("Not fully cleaned: the cleanup could not run — ") && mark.contains("git missing"), mark)
    }

    // MARK: - Clean Up screen beside the background cleanup

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

    // MARK: - Clean Up screen, a session's scope (F6, F8, F11)

    func testSessionScopeAppliesOnlyTheTickedRowsThenReloadsTheReport() async throws {
        let streamer = RepliedCleanupStreamer(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, cleanup) = makeVM(FakeSessionCleanupRunner(replies: []), streamer: streamer)
        let (p, row) = try await liveSession(vm)
        let (store, id) = (try XCTUnwrap(pool), row.id)
        streamer.onCall = { run in
            // Go stores the apply's result as it runs.
            guard run.args.contains("--apply") else { return }
            try? store.write { db in
                try db.execute(
                    sql: "UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = ? WHERE id = ?",
                    arguments: [String(bytes: CleanupFixture.applied, encoding: .utf8), "2026-10-12T10:00:00Z", id]
                )
            }
        }
        try await openScreen(vm, on: row)
        XCTAssertNil(vm.cleanupReportLine(sessionID: row.id), "nothing stored before the apply")
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
