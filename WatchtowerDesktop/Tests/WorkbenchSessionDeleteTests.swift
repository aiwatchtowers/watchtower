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
        window.open()
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private func makeVM(_ runner: FakeSessionCleanupRunner) -> (WorkbenchesViewModel, SessionCleanupCenter) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: terminals)
        vm.titleService = { _ in .init(title: "", written: false) }
        vm.deleteSleep = { [window] in await window?.wait($0) }
        let cleanup = SessionCleanupCenter(runner: runner)
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

    // MARK: - PROJ-18 guards

    func testProj18_DeleteAppliesOnlyThePlannedItems() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan), .success(CleanupFixture.applied)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let keys = vm.plannedDeleteRemovals(row)
        XCTAssertEqual(keys, CleanupFixture.plannedKeys, "the kept worktree is not offered")
        let ok = await vm.deleteAndCleanUp(row, items: keys)

        XCTAssertTrue(ok)
        let apply = try XCTUnwrap(applyCalls(runner).first)
        XCTAssertEqual(applyCalls(runner).count, 1)
        XCTAssertEqual(apply.filter { $0.hasPrefix("--item") }, keys.map { "--item=\($0)" },
                       "--apply names exactly the planned keys")
        XCTAssertTrue(apply.contains("--session=\(row.id)"))
        XCTAssertFalse(apply.contains("--live-session=\(row.id)"), "the terminal closed before the apply")
        XCTAssertFalse(terminals.liveIDs.contains(row.id))
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id), "then the normal deferred delete, with Undo")
        XCTAssertFalse(vm.sessions.contains { $0.id == row.id })
    }

    func testProj18_FailedCleanupKeepsTheSessionRow() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.plan),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "could not plan: git missing"))
        ])
        let (vm, cleanup) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, items: vm.plannedDeleteRemovals(row))

        XCTAssertFalse(ok)
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "the row is never deleted after a failed cleanup")
        XCTAssertFalse(vm.pendingDeletes.ids.contains(row.id), "not even into the Undo batch")
        XCTAssertTrue(vm.sessions.contains { $0.id == row.id }, "still listed")
        let error = try XCTUnwrap(vm.sessionErrors[p])
        XCTAssertTrue(error.contains("Cleanup failed") && error.contains("git missing"), error)
        XCTAssertNotNil(cleanup.failureText(for: .session(row.id)))
    }

    func testFailedItemKeepsTheSessionRow() async throws {
        let runner = FakeSessionCleanupRunner(replies: [
            .success(CleanupFixture.plan), .success(CleanupFixture.appliedWithError)
        ])
        let (vm, _) = makeVM(runner)
        let (p, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, items: vm.plannedDeleteRemovals(row))

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

    func testQuickDeleteNeverCleansUp() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.plan)])
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

        let intent = await vm.deleteQuicklyOrConfirm(row)

        XCTAssertEqual(intent, .quick)
        XCTAssertTrue(runner.calls.isEmpty, "the ✕ / ⌘⌫ path is Delete Only")
    }

    func testDeleteAndCleanUpWithNothingPlannedIsAPlainDelete() async throws {
        let runner = FakeSessionCleanupRunner(replies: [.success(CleanupFixture.emptyPlan)])
        let (vm, _) = makeVM(runner)
        let (_, row) = try await liveSession(vm)

        await vm.planCleanupBeforeDelete(row)
        let ok = await vm.deleteAndCleanUp(row, items: vm.plannedDeleteRemovals(row))

        XCTAssertTrue(ok)
        XCTAssertTrue(applyCalls(runner).isEmpty)
        XCTAssertTrue(vm.pendingDeletes.ids.contains(row.id))
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
}
