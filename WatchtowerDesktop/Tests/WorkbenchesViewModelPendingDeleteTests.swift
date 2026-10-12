import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Undo window's wait, held until the test ends it. Once opened, every
/// later wait returns at once, so a commit task that starts after `open()`
/// does not hang.
@MainActor
private final class DeleteWindowGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var waits: [Duration] = []

    func wait(_ duration: Duration) async {
        waits.append(duration)
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

private struct WriteRefused: LocalizedError {
    var errorDescription: String? { "database is locked" }
}

/// The deferred session delete with its batched Undo (board #480, PROJ-17,
/// spec 2026-10-12-sessions-panel-design §4.2–§4.3). No subprocess is
/// spawned: the terminal center runs fake processes.
@MainActor
final class WorkbenchesViewModelPendingDeleteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var center: TerminalCenter!
    private var gate: DeleteWindowGate!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelPendingDeleteTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt pending \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("acme"), withIntermediateDirectories: true)
        center = TerminalCenter { FakeTerminalSession(pid: 0) }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in true }
        gate = DeleteWindowGate()
    }

    override func tearDown() {
        // A cancelled commit task still parked in the gate finishes now.
        gate.open()
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Harness

    private var acme: String { folder.appendingPathComponent("acme").path }

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        vm.deleteSleep = { [gate] in await gate?.wait($0) }
        return vm
    }

    private func workbench(_ name: String = "acme") async throws -> Int64 {
        let path = folder.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: name, folder: path) }
    }

    private func insertSession(
        _ projectID: Int64?, title: String = "Session A", targetID: Int64? = nil, kind: TerminalSession.Kind = .claude
    ) async throws -> TerminalSession {
        let acme = acme
        return try await pool.write {
            try TerminalSessionQueries.create($0, .init(
                projectID: projectID, kind: kind, title: title, targetID: targetID, folderPath: acme,
                claudeSessionID: kind == .claude ? UUID().uuidString.lowercased() : nil
            ))
        }
    }

    /// A session with a report link to a target and an open ask bound to it.
    private func linkedSession(_ projectID: Int64) async throws -> (session: TerminalSession, askID: Int64) {
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: projectID, text: "Ship it") }
        let session = try await insertSession(projectID, targetID: target)
        let askID = try await pool.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO terminal_session_targets (session_id, target_id, first_at, last_at) VALUES (?, ?, ?, ?)",
                arguments: [session.id, target, "2026-10-12T10:00:00Z", "2026-10-12T10:05:00Z"]
            )
            return try TestDatabase.insertOwnerAsk(db, projectID: projectID, sessionID: session.id, targetID: target)
        }
        return (session, askID)
    }

    /// Everything PROJ-17's Undo promises back, column for column.
    private struct Snapshot: Equatable {
        let session: [Row]
        let links: [Row]
        let ask: [Row]
    }

    private func snapshot(_ sessionID: Int64, askID: Int64) async throws -> Snapshot {
        try await pool.read { db in
            try Snapshot(
                session: Row.fetchAll(db, sql: "SELECT * FROM terminal_sessions WHERE id = ?", arguments: [sessionID]),
                links: Row.fetchAll(db, sql: "SELECT * FROM terminal_session_targets WHERE session_id = ? ORDER BY target_id",
                                    arguments: [sessionID]),
                ask: Row.fetchAll(db, sql: "SELECT * FROM owner_asks WHERE id = ?", arguments: [askID])
            )
        }
    }

    private func stored(_ id: Int64) async throws -> TerminalSession? {
        try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
    }

    /// The Undo window ends: the parked commit task runs to its end.
    private func endWindow(_ vm: WorkbenchesViewModel) async {
        gate.open()
        await vm.deleteCommitTask?.value
    }

    // MARK: - PROJ-17 guards

    func testProj17_DeleteHidesAtOnceAndWritesNothingUntilTheWindowEnds() async throws {
        let p = try await workbench()
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.newSession(projectID: p)
        let row = try XCTUnwrap(vm.sessions.first)
        XCTAssertTrue(center.liveIDs.contains(row.id))

        await vm.delete(row)

        XCTAssertFalse(vm.sessions.contains { $0.id == row.id }, "hidden at once")
        XCTAssertNil(center.states[row.id], "the process stopped at once")
        XCTAssertEqual(vm.layout.visiblePanes, [.board], "it left the screen")
        XCTAssertEqual(vm.pendingDeleteToast, "Session deleted")
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "nothing written before the window ends")
        await vm.loadSessions(projectID: p)
        XCTAssertFalse(vm.sessions.contains { $0.id == row.id }, "a reload keeps it hidden")
        XCTAssertEqual(gate.waits, [.seconds(5)])

        await endWindow(vm)

        let gone = try await stored(row.id)
        XCTAssertNil(gone, "deleted once the window ended")
        XCTAssertNil(vm.pendingDeleteToast)
    }

    func testProj17_UndoBringsBackTheRowWithItsLinksAndAsks() async throws {
        let p = try await workbench()
        let (session, askID) = try await linkedSession(p)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.open(session)
        XCTAssertTrue(center.liveIDs.contains(session.id))
        let before = try await snapshot(session.id, askID: askID)
        XCTAssertEqual(before.links.count, 1)
        XCTAssertEqual(before.ask.first?["session_id"], session.id)

        await vm.delete(session)
        await vm.undoPendingDeletes()

        let after = try await snapshot(session.id, askID: askID)
        XCTAssertEqual(after, before, "row, links and ask byte-identical")
        XCTAssertTrue(vm.sessions.contains { $0.id == session.id }, "listed again")
        XCTAssertFalse(center.liveIDs.contains(session.id), "back not running")
        XCTAssertNil(vm.pendingDeleteToast)
        XCTAssertNil(vm.deleteCommitTask)
        await endWindow(vm)
        let still = try await snapshot(session.id, askID: askID)
        XCTAssertEqual(still, before, "the cancelled window commits nothing")
    }

    func testProj17_CommitAfterTheWindowDeletesWithCascades() async throws {
        let p = try await workbench()
        let (session, askID) = try await linkedSession(p)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)

        await vm.delete(session)
        await endWindow(vm)

        let after = try await snapshot(session.id, askID: askID)
        XCTAssertTrue(after.session.isEmpty)
        XCTAssertTrue(after.links.isEmpty, "the report links went by cascade (PROJ-02/14 unchanged)")
        XCTAssertEqual(after.ask.count, 1, "the ask stays")
        XCTAssertEqual(after.ask.first?["session_id"], DatabaseValue.null, "unbound by ON DELETE SET NULL")
    }

    func testProj17_QuitCommitsPendingDeletes() async throws {
        let p = try await workbench()
        let (session, askID) = try await linkedSession(p)
        let shell = try await insertSession(nil, kind: .shell)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)
        await vm.delete(session)
        await vm.delete(shell)

        vm.commitPendingDeletesForQuit()

        let after = try await snapshot(session.id, askID: askID)
        XCTAssertTrue(after.session.isEmpty, "deleted before the window ended")
        XCTAssertTrue(after.links.isEmpty)
        XCTAssertEqual(after.ask.first?["session_id"], DatabaseValue.null)
        let standalone = try await stored(shell.id)
        XCTAssertNil(standalone)
        XCTAssertTrue(vm.pendingDeletes.batch.isEmpty)
        XCTAssertNil(vm.deleteCommitTask, "the window's task is cancelled")
    }

    // MARK: - Supporting

    func testBatchUndoRestoresEverySessionOfTheBatch() async throws {
        let p = try await workbench()
        let a = try await insertSession(p, title: "Session A")
        let b = try await insertSession(p, title: "Session B")
        let shell = try await insertSession(nil, title: "Session C", kind: .shell)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)

        await vm.delete(a)
        await vm.delete(b)
        await vm.delete(shell)
        XCTAssertEqual(vm.pendingDeleteToast, "3 sessions deleted")
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertTrue(vm.standaloneSessions.isEmpty)

        await vm.undoPendingDeletes()

        XCTAssertEqual(Set(vm.sessions.map(\.id)), [a.id, b.id])
        XCTAssertEqual(vm.standaloneSessions.map(\.id), [shell.id])
        for id in [a.id, b.id, shell.id] {
            let row = try await stored(id)
            XCTAssertNotNil(row)
        }
    }

    func testFailedCommitBringsTheRowBackWithAnError() async throws {
        let p = try await workbench()
        let row = try await insertSession(p)
        let vm = makeVM()
        vm.commitSessionDeletes = { _ in throw WriteRefused() }
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)

        await vm.delete(row)
        XCTAssertTrue(vm.sessions.isEmpty)
        await endWindow(vm)

        XCTAssertEqual(vm.sessions.map(\.id), [row.id], "never kept hidden")
        XCTAssertEqual(vm.sessionErrors[p], "Could not delete the session: database is locked")
        XCTAssertTrue(vm.pendingDeletes.batch.isEmpty)
    }

    func testPendingRowIsInNoListGoToOrTargetLookup() async throws {
        let p = try await workbench()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Ship it") }
        let hidden = try await insertSession(p, targetID: target)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.open(hidden)
        XCTAssertEqual(vm.activeSessionID(projectID: p), hidden.id)

        await vm.delete(hidden)
        await vm.loadGoToPalette()

        XCTAssertFalse(vm.orderedSessions(projectID: p).contains { $0.id == hidden.id })
        XCTAssertFalse(vm.goToSessions.contains { $0.id == hidden.id })
        XCTAssertFalse(vm.goToSections(query: "").flatMap(\.items).contains {
            if case let .session(session, _) = $0 { return session.id == hidden.id }
            return false
        })
        XCTAssertNotEqual(vm.activeSessionID(projectID: p), hidden.id)

        await vm.workOn(targetID: target, targetText: "Ship it", projectID: p)

        let all = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: p) }
        XCTAssertEqual(all.count, 2, "Work on It started a new session, never the hidden one")
        XCTAssertFalse(center.liveIDs.contains(hidden.id))
        XCTAssertFalse(vm.sessions.contains { $0.id == hidden.id })
    }

    func testUndoStateSurvivesLeavingTheWorkbench() async throws {
        let p = try await workbench()
        let q = try await workbench("other")
        let row = try await insertSession(p)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)

        await vm.delete(row)
        vm.selectedWorkbenchID = q
        await vm.reload()
        XCTAssertEqual(vm.pendingDeleteToast, "Session deleted", "the toast's state is the view model's, not the page's")
        XCTAssertFalse(vm.terminalSessions[p]?.contains { $0.id == row.id } ?? false)

        await vm.undoPendingDeletes()

        XCTAssertEqual(vm.terminalSessions[p]?.map(\.id), [row.id])
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept)
    }

    /// A workbench deleted elsewhere (the list reload sees it vanish) while
    /// its session waits: the cascade removed it, the batch forgets it.
    func testAWorkbenchGoneElsewhereDropsItsPendingSessions() async throws {
        let p = try await workbench()
        let q = try await workbench("other")
        let gone = try await insertSession(p)
        let kept = try await insertSession(q)
        let vm = makeVM()
        await vm.reload()
        await vm.delete(gone)
        await vm.delete(kept)

        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [p]) }
        await vm.reload()

        XCTAssertEqual(vm.pendingDeletes.batch.map(\.sessionID), [kept.id])
        XCTAssertEqual(vm.pendingDeleteToast, "Session deleted")
        XCTAssertNotNil(vm.deleteCommitTask, "the rest of the batch still commits")
    }
}
