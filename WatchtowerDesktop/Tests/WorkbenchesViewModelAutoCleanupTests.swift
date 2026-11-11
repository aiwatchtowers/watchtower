import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Background apply results for the auto-cleanup tests (board #1716).
enum AutoCleanupFixture {
    /// Could not: the worktree is kept for a running process.
    static let processRunning = Data("""
    {"session_id":9,"workbench_id":2,"mode":"apply","items":[
      {"key":"worktree:/tmp/example/.claude/worktrees/x","kind":"worktree","name":"x","branch":"feat/x",
       "action":"keep","reason":"process_running"}
    ]}
    """.utf8)

    /// Nothing to remove: clean, no notice.
    static let nothing = Data(#"{"session_id":9,"workbench_id":2,"mode":"apply","items":[]}"#.utf8)
}

/// The background cleanup queue of deleted sessions (board #1716, spec
/// 2026-11-10-auto-cleanup-on-session-delete §1, §3, §4): outcomes, quit,
/// launch, Resume, the marked row's actions and the lists that hide a
/// deleting row. No subprocess is spawned: terminals are fake and the
/// cleanup CLI is a scripted streamer.
@MainActor
final class WorkbenchesViewModelAutoCleanupTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var terminals: TerminalCenter!
    private var streamers: [RepliedCleanupStreamer] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelAutoCleanupTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt auto \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("acme"), withIntermediateDirectories: true)
        terminals = TerminalCenter { FakeTerminalSession(pid: 0) }
        terminals.shell = { "/bin/zsh" }
        terminals.transcriptExists = { _ in true }
    }

    override func tearDown() {
        streamers.forEach { $0.finishAll() }
        streamers = []
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var acme: String { folder.appendingPathComponent("acme").path }

    /// The Undo window ends at once; the notice does not time out within a
    /// test.
    private func makeVM(_ replies: [Result<Data, Error>]) -> (WorkbenchesViewModel, SessionCleanupCenter, RepliedCleanupStreamer) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: terminals)
        vm.titleService = { _ in .init(title: "", written: false) }
        vm.deleteSleep = { _ in }
        vm.cleanupNoticeSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let streamer = RepliedCleanupStreamer(replies: replies)
        streamers.append(streamer)
        let cleanup = SessionCleanupCenter(runner: nil, streamer: streamer)
        cleanup.liveSessionIDs = { [terminals] in terminals?.liveIDs ?? [] }
        vm.sessionCleanup = cleanup
        return (vm, cleanup, streamer)
    }

    private func workbench() async throws -> Int64 {
        let acme = acme
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: acme) }
    }

    private func insertSession(_ p: Int64, title: String = "Fix the form", targetID: Int64? = nil) async throws -> TerminalSession {
        let acme = acme
        return try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: p, kind: .claude, title: title, targetID: targetID, folderPath: acme,
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
    }

    private func listed(_ vm: WorkbenchesViewModel, _ p: Int64) async {
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)
    }

    /// Deletes `row`; its Undo window ends at once and every queued
    /// cleanup runs to its end.
    private func deleteAndClean(_ vm: WorkbenchesViewModel, _ row: TerminalSession) async {
        await vm.delete(row)
        await vm.deleteCommitTask?.value
        await vm.autoCleanupIdle()
    }

    /// Deletes `row` and waits until its background apply is held.
    private func deleteHeld(
        _ vm: WorkbenchesViewModel, _ row: TerminalSession, _ streamer: RepliedCleanupStreamer, held: Int = 1
    ) async {
        await vm.delete(row)
        await vm.deleteCommitTask?.value
        await waitUntilHeld(streamer, held)
    }

    private func waitUntilHeld(_ streamer: RepliedCleanupStreamer, _ count: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while streamer.heldCount < count, Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThanOrEqual(streamer.heldCount, count, "the apply never started")
    }

    private func stored(_ id: Int64) async throws -> TerminalSession? {
        try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
    }

    private func deleteRequestedAt(_ id: Int64) async throws -> String? {
        try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT delete_requested_at FROM terminal_sessions WHERE id = ?", arguments: [id])
        }
    }

    private func applies(_ streamer: RepliedCleanupStreamer) -> [[String]] {
        streamer.calls.map(\.args).filter { $0.contains("--apply") }
    }

    /// A row marked Not fully cleaned (a could-not first apply).
    private func markedRow(_ vm: WorkbenchesViewModel, _ p: Int64) async throws -> TerminalSession {
        let row = try await insertSession(p)
        await listed(vm, p)
        await deleteAndClean(vm, row)
        XCTAssertNotNil(vm.notFullyCleaned[row.id])
        return row
    }

    // MARK: - Outcomes

    func testCleanOutcomeDeletesTheRowAndShowsTheNotice() async throws {
        let (vm, _, _) = makeVM([.success(CleanupFixture.applied)])
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)

        await deleteAndClean(vm, row)

        let gone = try await stored(row.id)
        XCTAssertNil(gone)
        XCTAssertEqual(vm.cleanupNotice?.text, "Cleaned up “Fix the form”: removed 1 worktree and 1 branch (~2.0 GB).")
    }

    func testNothingRemovedDeletesTheRowWithoutANotice() async throws {
        let (vm, _, _) = makeVM([.success(AutoCleanupFixture.nothing)])
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)

        await deleteAndClean(vm, row)

        let gone = try await stored(row.id)
        XCTAssertNil(gone)
        XCTAssertNil(vm.cleanupNotice)
    }

    func testKeptOnPurposeStillDeletesRow() async throws {
        let (vm, _, _) = makeVM([.success(CleanupFixture.appliedKeptBranch)])
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)

        await deleteAndClean(vm, row)

        let gone = try await stored(row.id)
        XCTAssertNil(gone, "kept for the owner's work is not a failure")
        XCTAssertNil(vm.notFullyCleaned[row.id])
        XCTAssertEqual(vm.cleanupNotice?.text, "Cleaned up “Fix the form”: removed 1 worktree. Kept 1 branch — unpushed commits.")
    }

    func testDeletesInARowJoinIntoOneNotice() async throws {
        let (vm, _, _) = makeVM([.success(CleanupFixture.applied)])
        let p = try await workbench()
        let a = try await insertSession(p, title: "A")
        let b = try await insertSession(p, title: "B")
        await listed(vm, p)

        await deleteAndClean(vm, a)
        await deleteAndClean(vm, b)

        XCTAssertEqual(vm.cleanupNotice?.text, "Cleaned up 2 sessions: removed 2 worktrees and 2 branches (~4.0 GB).")
    }

    func testTheNoticeLeavesAfterItsTime() async throws {
        let (vm, _, _) = makeVM([.success(CleanupFixture.applied)])
        var waits: [Duration] = []
        vm.cleanupNoticeSleep = { waits.append($0) }
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)

        await deleteAndClean(vm, row)
        await vm.cleanupNoticeTask?.value

        XCTAssertEqual(waits, [.seconds(6)])
        XCTAssertNil(vm.cleanupNotice)
    }

    /// The queue runs one cleanup at a time per workbench, in request order.
    func testOneCleanupAtATimePerWorkbench() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        streamer.holdsCalls = true
        let p = try await workbench()
        let a = try await insertSession(p, title: "A")
        let b = try await insertSession(p, title: "B")
        await listed(vm, p)

        await vm.delete(a)
        await vm.delete(b)
        await vm.deleteCommitTask?.value
        await waitUntilHeld(streamer, 1)
        XCTAssertEqual(vm.autoCleanupQueue[p], [a.id, b.id])
        XCTAssertEqual(vm.autoCleanupCount(projectID: p), 2)
        XCTAssertEqual(applies(streamer).count, 1, "b waits for a")

        streamer.holdsCalls = false
        streamer.release()
        await vm.autoCleanupIdle()
        XCTAssertEqual(applies(streamer).map { $0.first { $0.hasPrefix("--session=") } },
                       ["--session=\(a.id)", "--session=\(b.id)"])
        XCTAssertNil(vm.autoCleanupQueue[p])
    }

    // MARK: - Clean Up screen beside the queue (Review Focus 5)

    /// A Clean Up screen apply while the queue runs waits for the slot and
    /// is not refused; the queue's next item waits for it.
    func testScreenApplyWaitsForQueueSlot() async throws {
        let (vm, _, streamer) = makeVM([
            .success(CleanupFixture.applied), // a's background apply
            .success(CleanupFixture.plan), // the screen's plan
            .success(CleanupFixture.applied), // the screen's apply
            .success(CleanupFixture.applied) // b's background apply
        ])
        let p = try await workbench()
        let a = try await insertSession(p, title: "A")
        let b = try await insertSession(p, title: "B")
        let other = try await insertSession(p, title: "Other")
        await listed(vm, p)
        streamer.holdsCalls = true
        await deleteHeld(vm, a, streamer)

        streamer.holdsCalls = false
        await vm.openCleanupScreen(projectID: p, sessionID: other.id).value
        vm.cleanupScreens[p]?.ticks = ["worktree:/tmp/example/.claude/worktrees/x"]
        XCTAssertTrue(vm.canRefreshCleanup(projectID: p), "the background cleanup does not block the screen")
        let screen = Task { await vm.applyCleanupScreen(projectID: p) }
        await waitUntil("the screen's apply waits") { vm.sweepRuns[p] != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(applies(streamer).count, 1, "it waits for the slot: nothing launched yet")
        await vm.delete(b)
        await vm.deleteCommitTask?.value
        XCTAssertEqual(vm.autoCleanupQueue[p], [a.id, b.id])

        streamer.release()
        let ok = await screen.value
        XCTAssertTrue(ok, "never refused")
        await vm.autoCleanupIdle()
        let order = applies(streamer).map { $0.first { $0.hasPrefix("--session=") } }
        XCTAssertEqual(order, ["--session=\(a.id)", "--session=\(other.id)", "--session=\(b.id)"],
                       "the queue's next item waited for the screen's apply")
    }

    // MARK: - Time limit

    func testTimeoutIsCouldNot() async throws {
        let (vm, cleanup, streamer) = makeVM([.success(CleanupFixture.applied)])
        streamer.holdsCalls = true
        let clock = AsyncGateClock()
        cleanup.backgroundSleep = { duration in await clock.sleep(duration) }
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)
        await deleteHeld(vm, row, streamer)

        await clock.untilWaiting()
        XCTAssertEqual(clock.waited, [.seconds(600)], "a 10-minute limit")
        clock.pass()
        await vm.autoCleanupIdle()

        XCTAssertEqual(streamer.runs.first?.groupStopGraces, [.seconds(5)], "SIGTERM to the group, SIGKILL after 5 s")
        XCTAssertEqual(vm.notFullyCleaned[row.id], "Not fully cleaned: the cleanup took longer than 10 minutes.")
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
    }

    // MARK: - Quit and launch (Review Focus 4)

    func testQuitInsideWindowMarksInsteadOfDeleting() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        let held = HeldSleep()
        vm.deleteSleep = { await held.wait($0) }
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)
        await vm.delete(row)

        let finished = await vm.commitPendingDeletesForQuit()

        XCTAssertTrue(finished)
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "not deleted at quit")
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested, "marked: the next launch cleans it up")
        XCTAssertTrue(streamer.calls.isEmpty, "no cleanup starts during the quit")
        held.open()
    }

    func testQuitStopsRunningApplyAndKeepsMark() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        streamer.holdsCalls = true
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)
        await deleteHeld(vm, row, streamer)

        await vm.stopAutoCleanupForQuit()
        await vm.autoCleanupIdle()

        XCTAssertEqual(streamer.runs.first?.groupStopGraces, [.seconds(5)], "its process group was stopped")
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested, "the mark stays for the next launch")
        XCTAssertNil(vm.notFullyCleaned[row.id], "nothing decided at quit")
    }

    func testRequeueAtLaunchRunsOncePerRow() async throws {
        let p = try await workbench()
        let a = try await insertSession(p, title: "A")
        let b = try await insertSession(p, title: "B")
        try await pool.write { try TerminalSessionQueries.markDeleteRequested($0, ids: [a.id, b.id], at: Date()) }
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning)])

        await vm.requeueDeletingRowsAtLaunch()
        await vm.autoCleanupIdle()
        await vm.requeueDeletingRowsAtLaunch()
        await vm.autoCleanupIdle()

        XCTAssertEqual(applies(streamer).count, 2, "one apply per row, once per launch: no retry loop")
        XCTAssertNotNil(vm.notFullyCleaned[a.id])
        XCTAssertNotNil(vm.notFullyCleaned[b.id])
        XCTAssertEqual(Set(vm.notFullyCleanedRows[p]?.map(\.id) ?? []), [a.id, b.id])
    }

    func testRequeueSkipsRowWithLiveTerminal() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)
        await vm.open(row)
        XCTAssertTrue(terminals.liveIDs.contains(row.id))
        try await pool.write { try TerminalSessionQueries.markDeleteRequested($0, ids: [row.id], at: Date()) }

        await vm.requeueDeletingRowsAtLaunch()
        await vm.autoCleanupIdle()

        XCTAssertTrue(streamer.calls.isEmpty, "a row that is live again is left alone")
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
    }

    // MARK: - Resume

    func testResumeClearsDeleteRequested() async throws {
        let (vm, _, _) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        await vm.open(row)

        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNil(requested, "an ordinary finished session again")
        XCTAssertNil(vm.notFullyCleaned[row.id])
        XCTAssertTrue(vm.notFullyCleanedRows[p]?.isEmpty ?? true)
        XCTAssertTrue(terminals.liveIDs.contains(row.id), "resumed")
        await vm.loadSessions(projectID: p)
        XCTAssertTrue(vm.sessions.contains { $0.id == row.id }, "listed again")
    }

    func testResumeDisabledWhileCleaning() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)
        streamer.holdsCalls = true

        vm.cleanUpAgain(row.id)
        await waitUntilHeld(streamer, 1)
        XCTAssertFalse(vm.canResume(row.id))
        do {
            try await vm.resume(row)
            XCTFail("no resume while Clean Up Again runs")
        } catch let error as WorkbenchesViewModel.TargetStartError {
            XCTAssertEqual(error, .cleaningUp)
        }

        XCTAssertFalse(terminals.liveIDs.contains(row.id), "no resume while its cleanup runs")
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested, "the delete request stays")
        streamer.release()
        await vm.autoCleanupIdle()
    }

    // MARK: - The marked row's actions

    func testCleanUpAgainSuccessDeletesRow() async throws {
        let (vm, _, _) = makeVM([.success(AutoCleanupFixture.processRunning), .success(CleanupFixture.applied)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        vm.cleanUpAgain(row.id)
        // Spec §7 state 8: listed, "Cleaning up…", its actions off.
        XCTAssertEqual(vm.notFullyCleanedRows[p]?.map(\.id), [row.id], "listed while it runs")
        XCTAssertTrue(vm.cleaningAgain.contains(row.id))
        XCTAssertNil(vm.notFullyCleaned[row.id])
        vm.cleanUpAgain(row.id)
        XCTAssertEqual(vm.autoCleanupCount(projectID: p), 1, "a second press queues nothing")
        await vm.autoCleanupIdle()

        let gone = try await stored(row.id)
        XCTAssertNil(gone)
        XCTAssertNil(vm.notFullyCleaned[row.id])
        XCTAssertFalse(vm.cleaningAgain.contains(row.id))
        XCTAssertTrue(vm.notFullyCleanedRows[p]?.isEmpty ?? true, "gone once clean")
    }

    /// Review #804: a marked row's report survives a list reload (the
    /// view's reload skips it, and the layout keeps it), and a pane of a
    /// marked or queued row is not pruned by the reload either.
    func testNotFullyCleanedPaneSurvivesSessionReload() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning), .success(CleanupFixture.applied)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        vm.openNotFullyCleaned(row.id, projectID: p)
        await vm.loadSessions(projectID: p)
        XCTAssertEqual(vm.layout(projectID: p).primary, .sessionReport(row.id), "the report stays")
        XCTAssertEqual(vm.reportSession(row.id, projectID: p)?.id, row.id)

        var layout = vm.layout(projectID: p)
        layout.show(.sessionChat(row.id))
        vm.setLayout(layout, projectID: p)
        await vm.loadSessions(projectID: p)
        XCTAssertTrue(vm.layout(projectID: p).referencedSessionIDs.contains(row.id), "marked: its pane stays")

        streamer.holdsCalls = true
        vm.cleanUpAgain(row.id)
        await waitUntilHeld(streamer, 1)
        await vm.loadSessions(projectID: p)
        XCTAssertTrue(vm.layout(projectID: p).referencedSessionIDs.contains(row.id), "queued: its pane stays")
        streamer.release()
        await vm.autoCleanupIdle()
        XCTAssertFalse(vm.layout(projectID: p).referencedSessionIDs.contains(row.id), "clean: the pane goes with the row")
    }

    /// Review #804 item 11: a quit while Clean Up Again runs leaves the row
    /// marked deleted; the next launch queues it again.
    func testQuitDuringCleanUpAgainRequeuesAtLaunch() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning), .success(CleanupFixture.applied)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)
        streamer.holdsCalls = true
        vm.cleanUpAgain(row.id)
        await waitUntilHeld(streamer, 1)

        await vm.stopAutoCleanupForQuit()
        await vm.autoCleanupIdle()
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested, "the delete request survives the quit")

        let (next, _, nextStreamer) = makeVM([.success(CleanupFixture.applied)])
        await next.requeueDeletingRowsAtLaunch()
        await next.autoCleanupIdle()

        XCTAssertEqual(applies(nextStreamer).count, 1, "queued again at launch")
        let gone = try await stored(row.id)
        XCTAssertNil(gone)
    }

    func testOpenNotFullyCleanedShowsItsReport() async throws {
        let (vm, _, _) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        vm.openNotFullyCleaned(row.id, projectID: p)

        XCTAssertEqual(vm.layout(projectID: p).primary, .sessionReport(row.id))
        XCTAssertEqual(vm.reportSession(row.id, projectID: p)?.id, row.id, "the report finds the marked row")
        XCTAssertNil(vm.session(row.id, projectID: p), "still out of the session lists")
    }

    func testCleanUpAgainFailureKeepsNewMark() async throws {
        let (vm, _, _) = makeVM([
            .success(AutoCleanupFixture.processRunning), .success(CleanupFixture.appliedWithError)
        ])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        vm.cleanUpAgain(row.id)
        await vm.autoCleanupIdle()

        XCTAssertFalse(vm.cleaningAgain.contains(row.id))
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
        XCTAssertEqual(vm.notFullyCleaned[row.id], "Not fully cleaned: 1 branch — could not be removed.")
        XCTAssertEqual(vm.notFullyCleanedRows[p]?.map(\.id), [row.id])
    }

    func testDeleteAnywayDeletesRow() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        await vm.deleteAnyway(row.id)

        let gone = try await stored(row.id)
        XCTAssertNil(gone)
        XCTAssertNil(vm.notFullyCleaned[row.id])
        XCTAssertTrue(vm.notFullyCleanedRows[p]?.isEmpty ?? true)
        XCTAssertEqual(applies(streamer).count, 1, "no further cleanup")
    }

    func testShowInCleanUpOpensScreenScopedToSession() async throws {
        let (vm, _, _) = makeVM([.success(AutoCleanupFixture.processRunning), .success(CleanupFixture.plan)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        await vm.showInCleanUp(row.id)?.value

        XCTAssertEqual(vm.cleanupScreens[p]?.scope, .session(row.id))
    }

    /// The report of a Not fully cleaned row shows its Cleanup section from
    /// what the apply stored (`cleanup_result`).
    func testNotFullyCleanedReportShowsCleanupSection() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.appliedWithError)])
        let p = try await workbench()
        let row = try await insertSession(p)
        let store = try XCTUnwrap(pool)
        let id = row.id
        streamer.onCall = { _ in
            try? store.write { db in
                try db.execute(
                    sql: "UPDATE terminal_sessions SET cleanup_result = ?, cleanup_at = ? WHERE id = ?",
                    arguments: [String(bytes: CleanupFixture.appliedWithError, encoding: .utf8), "2026-11-10T10:00:00Z", id]
                )
            }
        }
        await listed(vm, p)

        await deleteAndClean(vm, row)

        XCTAssertNotNil(vm.notFullyCleaned[row.id])
        XCTAssertEqual(vm.cleanupRecords[row.id]?.at, "2026-11-10T10:00:00Z")
        XCTAssertEqual(vm.cleanupRecords[row.id]?.result?.items.first?.error, "cannot lock ref",
                       "the report's Cleanup section reads what the apply stored")
    }

    // MARK: - Exclusive transitions of a marked row (review #800)

    /// Resume first: while its write clears the delete request, Clean Up
    /// Again and Delete Anyway refuse the row.
    func testResumeRefusesCleanUpAgainAndDeleteAnywayMeanwhile() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)
        let gate = WriteGate()
        let store = try XCTUnwrap(pool)
        vm.clearDeleteRequestWrite = { id in
            await gate.wait()
            try await store.write { try TerminalSessionQueries.clearDeleteRequested($0, id: id) }
        }

        let resume = Task { try await vm.resume(row) }
        await waitUntil("the resume holds the row") { vm.autoCleanupBusy.contains(row.id) }
        vm.cleanUpAgain(row.id)
        XCTAssertNil(vm.autoCleanupQueue[p], "Clean Up Again refused")
        await vm.deleteAnyway(row.id)
        let still = try await stored(row.id)
        XCTAssertNotNil(still, "Delete Anyway refused")

        gate.open()
        _ = try await resume.value
        XCTAssertTrue(terminals.liveIDs.contains(row.id), "resumed")
        XCTAssertNil(vm.notFullyCleaned[row.id])
        XCTAssertEqual(applies(streamer).count, 1, "no second cleanup")
    }

    /// Delete Anyway first: while its DELETE runs, Resume (`.cleaningUp`)
    /// and Clean Up Again refuse the row.
    func testDeleteAnywayRefusesResumeAndCleanUpAgainMeanwhile() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)
        let gate = WriteGate()
        let store = try XCTUnwrap(pool)
        vm.commitSessionDeletes = { ids in
            await gate.wait()
            try await store.write { db in for id in ids { try TerminalSessionQueries.delete(db, id: id) } }
        }

        let deleting = Task { await vm.deleteAnyway(row.id) }
        await waitUntil("Delete Anyway holds the row") { vm.autoCleanupBusy.contains(row.id) }
        do {
            try await vm.resume(row)
            XCTFail("no resume while Delete Anyway runs")
        } catch let error as WorkbenchesViewModel.TargetStartError {
            XCTAssertEqual(error, .cleaningUp)
        }
        vm.cleanUpAgain(row.id)
        XCTAssertNil(vm.autoCleanupQueue[p], "Clean Up Again refused")

        gate.open()
        await deleting.value
        let gone = try await stored(row.id)
        XCTAssertNil(gone)
        XCTAssertFalse(terminals.liveIDs.contains(row.id))
        XCTAssertEqual(applies(streamer).count, 1)
    }

    /// Delete Anyway refuses a row a Clean Up screen apply or a background
    /// cleanup runs on.
    func testDeleteAnywayRefusesARowACleanupRunsOn() async throws {
        let (vm, _, streamer) = makeVM([
            .success(AutoCleanupFixture.processRunning), .success(CleanupFixture.plan),
            .success(CleanupFixture.appliedKeptBranch), .success(AutoCleanupFixture.processRunning)
        ])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        await vm.showInCleanUp(row.id)?.value
        vm.cleanupScreens[p]?.ticks = ["worktree:/tmp/example/.claude/worktrees/x"]
        streamer.holdsCalls = true
        let screen = Task { await vm.applyCleanupScreen(projectID: p) }
        await waitUntilHeld(streamer, 1)
        await vm.deleteAnyway(row.id)
        var still = try await stored(row.id)
        XCTAssertNotNil(still, "refused while the screen's apply runs on it")
        streamer.release()
        _ = await screen.value
        vm.closeCleanupScreen(projectID: p)

        vm.cleanUpAgain(row.id)
        await waitUntilHeld(streamer, 1)
        await vm.deleteAnyway(row.id)
        still = try await stored(row.id)
        XCTAssertNotNil(still, "refused while its background cleanup runs")
        streamer.holdsCalls = false
        streamer.release()
        await vm.autoCleanupIdle()
    }

    /// Start fresh never runs a Not fully cleaned row, nor one whose
    /// cleanup runs again: Resume is its way back.
    func testStartFreshRefusesADeletedRow() async throws {
        let (vm, _, streamer) = makeVM([.success(AutoCleanupFixture.processRunning)])
        let p = try await workbench()
        let row = try await markedRow(vm, p)

        await vm.startFresh(row)
        XCTAssertFalse(terminals.liveIDs.contains(row.id), "a marked row does not start fresh")
        XCTAssertNotNil(vm.notFullyCleaned[row.id])
        let requested = try await deleteRequestedAt(row.id)
        XCTAssertNotNil(requested)

        streamer.holdsCalls = true
        vm.cleanUpAgain(row.id)
        await waitUntilHeld(streamer, 1)
        await vm.startFresh(row)
        XCTAssertFalse(terminals.liveIDs.contains(row.id), "nor while its cleanup runs")
        streamer.release()
        await vm.autoCleanupIdle()
    }

    /// The Clean Up screen's session-scope apply refuses a row a Delete
    /// Anyway is changing, and one whose background cleanup runs.
    func testScreenApplyRefusesADeletedRowInTransition() async throws {
        let (vm, _, streamer) = makeVM([
            .success(AutoCleanupFixture.processRunning), .success(CleanupFixture.plan),
            .success(AutoCleanupFixture.processRunning)
        ])
        let p = try await workbench()
        let row = try await markedRow(vm, p)
        await vm.showInCleanUp(row.id)?.value
        vm.cleanupScreens[p]?.ticks = ["worktree:/tmp/example/.claude/worktrees/x"]
        let gate = WriteGate()
        let store = try XCTUnwrap(pool)
        vm.commitSessionDeletes = { ids in
            await gate.wait()
            try await store.write { db in for id in ids { try TerminalSessionQueries.delete(db, id: id) } }
        }

        streamer.holdsCalls = true
        vm.cleanUpAgain(row.id)
        await waitUntilHeld(streamer, 1)
        var applied = await vm.applyCleanupScreen(projectID: p)
        XCTAssertFalse(applied, "refused while its background cleanup runs")
        XCTAssertEqual(applies(streamer).count, 2, "only the two background applies")
        streamer.holdsCalls = false
        streamer.release()
        await vm.autoCleanupIdle()
        XCTAssertNotNil(vm.notFullyCleaned[row.id])

        let deleting = Task { await vm.deleteAnyway(row.id) }
        await waitUntil("Delete Anyway holds the row") { vm.autoCleanupBusy.contains(row.id) }
        applied = await vm.applyCleanupScreen(projectID: p)
        XCTAssertFalse(applied, "refused while Delete Anyway runs")
        XCTAssertEqual(applies(streamer).count, 2)
        gate.open()
        await deleting.value
    }

    // MARK: - Queue edges (review #800)

    func testTwoWorkbenchesCleanUpInParallel() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        streamer.holdsCalls = true
        let p = try await workbench()
        let otherFolder = folder.appendingPathComponent("other").path
        try FileManager.default.createDirectory(atPath: otherFolder, withIntermediateDirectories: true)
        let q = try await pool.write { try TestDatabase.insertWorkbench($0, name: "other", folder: otherFolder) }
        let a = try await insertSession(p, title: "A")
        let b = try await insertSession(q, title: "B")
        await listed(vm, p)

        await vm.delete(a)
        await vm.delete(b)
        await vm.deleteCommitTask?.value
        await waitUntilHeld(streamer, 2)

        XCTAssertEqual(applies(streamer).count, 2, "one apply per workbench at the same time")
        streamer.holdsCalls = false
        streamer.release()
        await vm.autoCleanupIdle()
    }

    /// A workbench gone: only the row whose cleanup started stays queued;
    /// the others and their titles go. A row queued but not started yet goes
    /// too.
    func testDiscardKeepsOnlyTheStartedRow() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        streamer.holdsCalls = true
        let p = try await workbench()
        let a = try await insertSession(p, title: "A")
        let b = try await insertSession(p, title: "B")
        await listed(vm, p)
        await vm.delete(a)
        await vm.delete(b)
        await vm.deleteCommitTask?.value
        await waitUntilHeld(streamer, 1)

        vm.discardAutoCleanup(workbenchID: p)

        XCTAssertEqual(vm.autoCleanupQueue[p], [a.id])
        XCTAssertNil(vm.autoCleanupTitles[b.id])
        XCTAssertFalse(vm.closedForCleanup.contains(b.id))
        streamer.holdsCalls = false
        streamer.release()
        await vm.autoCleanupIdle()
        XCTAssertEqual(applies(streamer).count, 1, "b never ran")

        let c = try await insertSession(p, title: "C")
        vm.enqueueAutoCleanup([.init(sessionID: c.id, workbenchID: p, title: "C")])
        vm.discardAutoCleanup(workbenchID: p)
        XCTAssertNil(vm.autoCleanupQueue[p], "not started yet: dropped")
        await vm.autoCleanupIdle()
        XCTAssertEqual(applies(streamer).count, 1)
    }

    /// A row still marked deleted whose terminal was live at launch is
    /// cleaned up once that terminal ends.
    func testMarkedRowLiveAtLaunchIsCleanedWhenItsTerminalEnds() async throws {
        let (vm, _, streamer) = makeVM([.success(CleanupFixture.applied)])
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)
        await vm.open(row)
        try await pool.write { try TerminalSessionQueries.markDeleteRequested($0, ids: [row.id], at: Date()) }
        await vm.requeueDeletingRowsAtLaunch()
        XCTAssertTrue(streamer.calls.isEmpty)

        await terminals.close(sessionID: row.id)
        vm.sessionExited(row.id, code: 0)
        await vm.autoCleanupIdle()

        XCTAssertEqual(applies(streamer).count, 1)
        let gone = try await stored(row.id)
        XCTAssertNil(gone)
    }

    func testDeleteFailureAfterACleanApplyKeepsTheRowMarked() async throws {
        let (vm, _, _) = makeVM([.success(CleanupFixture.applied)])
        vm.commitSessionDeletes = { _ in throw WriteRefusedError() }
        let p = try await workbench()
        let row = try await insertSession(p)
        await listed(vm, p)

        await deleteAndClean(vm, row)

        XCTAssertEqual(vm.notFullyCleaned[row.id], "Not fully cleaned: the session could not be deleted — database is locked.")
        XCTAssertEqual(vm.notFullyCleanedRows[p]?.map(\.id), [row.id])
    }

    // MARK: - Lists hide a deleting row

    func testDeletingRowsHiddenFromLists() async throws {
        let p = try await workbench()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Ship it") }
        let kept = try await insertSession(p, title: "Kept")
        let deleting = try await insertSession(p, title: "Deleting", targetID: target)
        let shell = try await pool.write {
            try TerminalSessionQueries.create($0, .init(projectID: nil, kind: .shell, title: "sh", targetID: nil, folderPath: "/tmp"))
        }
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, ?, ?)",
                arguments: [deleting.id, target, "2026-11-10T10:00:00Z", "2026-11-10T10:05:00Z"]
            )
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = '2099-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [deleting.id])
            try TerminalSessionQueries.markDeleteRequested(db, ids: [deleting.id, shell.id], at: Date())
        }

        try await pool.read { db in
            XCTAssertEqual(try TerminalSessionQueries.fetchForWorkbench(db, projectID: p).map(\.id), [kept.id])
            XCTAssertEqual(try TerminalSessionQueries.fetchAllWorkbenchSessions(db).map(\.id), [kept.id])
            XCTAssertEqual(try TerminalSessionQueries.fetchStandalone(db).map(\.id), [])
            XCTAssertEqual(try TerminalSessionQueries.fetchForTarget(db, targetID: target).map(\.id), [])
            XCTAssertNil(try TerminalSessionQueries.fetchWorkLinks(db, projectID: p)[deleting.id])
            let activity = try WorkbenchQueries.switcherSummaries(db).first { $0.id == p }?.lastSessionActivity
            XCTAssertNotEqual(activity, "2099-01-01T00:00:00Z", "the activity ordering skips it")
            XCTAssertEqual(try TerminalSessionQueries.fetchDeleting(db, projectID: p).map(\.id), [deleting.id])
        }
        XCTAssertEqual(HubKeepAwake.liveBoardSessions(pool, liveIDs: [deleting.id]), 0, "keeps nothing awake")
        XCTAssertEqual(HubKeepAwake.liveBoardSessions(pool, liveIDs: [kept.id]), 1)
    }

    func testDeletingRowGivesNoAgentStateNotice() async throws {
        let p = try await workbench()
        let kept = try await insertSession(p, title: "Kept")
        let deleting = try await insertSession(p, title: "Deleting")
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET agent_state = 'waiting', agent_cwd = '/tmp/x', "
                + "agent_cwd_at = '2026-11-10T10:00:00Z'")
            try TerminalSessionQueries.markDeleteRequested(db, ids: [deleting.id], at: Date())
        }

        try await pool.read { db in
            let states = try TerminalSessionQueries.fetchAgentStates(db, liveIDs: [deleting.id])
            XCTAssertEqual(states.map(\.id), [kept.id], "no notice or badge from a deleting row")
            XCTAssertEqual(Array(try TerminalSessionQueries.fetchAgentCwds(db, projectID: p).keys), [kept.id])
        }
    }
}

private struct WriteRefusedError: LocalizedError {
    var errorDescription: String? { "database is locked" }
}

/// A write held until `open()`.
@MainActor
private final class WriteGate: @unchecked Sendable {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
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

/// A sleep the test lets pass by hand: records what was asked.
@MainActor
private final class AsyncGateClock: @unchecked Sendable {
    private(set) var waited: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private var watchers: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async {
        waited.append(duration)
        await withCheckedContinuation { continuation in
            sleepers.append(continuation)
            let waiting = watchers
            watchers = []
            waiting.forEach { $0.resume() }
        }
    }

    func untilWaiting() async {
        guard sleepers.isEmpty else { return }
        await withCheckedContinuation { watchers.append($0) }
    }

    /// Every sleep ends: its time has passed.
    func pass() {
        let resumed = sleepers
        sleepers = []
        resumed.forEach { $0.resume() }
    }
}

/// The Undo window held until `open()`.
@MainActor
private final class HeldSleep {
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
