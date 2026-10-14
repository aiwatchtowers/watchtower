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

/// A running session's close held in its kill grace: the process stays
/// "alive" and the grace's poll parks until `release()`.
@MainActor
private final class CloseGate {
    private(set) var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkWatchers: [CheckedContinuation<Void, Never>] = []

    func pollStep() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            parked.append(continuation)
            let watchers = parkWatchers
            parkWatchers = []
            watchers.forEach { $0.resume() }
        }
    }

    /// Returns once a close is parked in its grace.
    func untilParked() async {
        guard parked.isEmpty else { return }
        await withCheckedContinuation { parkWatchers.append($0) }
    }

    func release() {
        released = true
        let resumed = parked
        parked = []
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

    /// A terminal center whose running sessions close only once `gate`
    /// releases them (the kill grace of a process that does not exit).
    private func slowClosingCenter(_ gate: CloseGate) -> TerminalCenter {
        let slow = TerminalCenter(
            makeProcess: { FakeTerminalSession(pid: 4242) },
            signaller: ProcessGroupSignaller(
                signal: { _, _ in },
                isAlive: { [gate] _ in !gate.released },
                sleep: { [gate] _ in await gate.pollStep() }
            )
        )
        slow.shell = { "/bin/zsh" }
        slow.transcriptExists = { _ in true }
        return slow
    }

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

    // MARK: - Closes in their kill grace (F1, F5)

    /// B is deleted while A's window runs and B's process takes its grace:
    /// B restarts the window before its close, and the window's end commits
    /// nothing until B's close finished.
    func testADeleteDuringAnotherClosesGraceWaitsForThatClose() async throws {
        let closing = CloseGate()
        center = slowClosingCenter(closing)
        let p = try await workbench()
        let a = try await insertSession(p, title: "Session A")
        let b = try await insertSession(p, title: "Session B")
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.open(b)
        XCTAssertTrue(center.liveIDs.contains(b.id))

        await vm.delete(a)
        let deletingB = Task { await vm.delete(b) }
        await closing.untilParked()
        XCTAssertEqual(gate.waits, [.seconds(5), .seconds(5)], "B restarted the window before its close")
        XCTAssertEqual(vm.pendingDeleteToast, "2 sessions deleted")

        await endWindow(vm)
        let keptA = try await stored(a.id)
        let keptB = try await stored(b.id)
        XCTAssertNotNil(keptA, "the batch waits for B's close")
        XCTAssertNotNil(keptB, "never deleted while its process is alive")
        XCTAssertEqual(vm.pendingDeleteToast, "2 sessions deleted")

        closing.release()
        await deletingB.value
        let goneA = try await stored(a.id)
        let goneB = try await stored(b.id)
        XCTAssertNil(goneA)
        XCTAssertNil(goneB, "committed once its close finished")
        XCTAssertNil(vm.pendingDeleteToast)
    }

    func testUndoWhileTheCloseIsPendingCommitsNothing() async throws {
        let closing = CloseGate()
        center = slowClosingCenter(closing)
        let p = try await workbench()
        let b = try await insertSession(p)
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.open(b)

        let deletingB = Task { await vm.delete(b) }
        await closing.untilParked()
        await vm.undoPendingDeletes()
        XCTAssertTrue(vm.sessions.contains { $0.id == b.id }, "listed again at once")
        XCTAssertNil(vm.pendingDeleteToast)

        closing.release()
        await deletingB.value
        await endWindow(vm)
        let kept = try await stored(b.id)
        XCTAssertNotNil(kept, "the finished close commits nothing")
        XCTAssertTrue(vm.sessions.contains { $0.id == b.id })
        XCTAssertFalse(center.liveIDs.contains(b.id), "back not running")
    }

    // MARK: - Asks of a pending session (F2)

    func testAskOfAPendingSessionSaysTheSessionIsGone() async throws {
        let p = try await workbench()
        let (session, askID) = try await linkedSession(p)
        _ = try await insertSession(p, title: "Other")
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)
        await vm.delete(session)

        let shown = await vm.showAsk(askID, projectID: p)

        XCTAssertTrue(shown, "the ask itself exists")
        XCTAssertEqual(vm.sessionErrors[p], "That session no longer exists.")
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.board], "no other session put on screen")
        XCTAssertNil(vm.asks.drawerAskIDs[p])
        XCTAssertFalse(center.liveIDs.contains(session.id), "never resumed")
    }

    /// Board #542: once the window commits, the asks are read again at once
    /// — the ask is session-less, says so, and a click opens its drawer at
    /// the page's trailing edge instead of nothing.
    func testAskOfACommittedDeleteOpensAtThePageEdge() async throws {
        let p = try await workbench()
        let (session, askID) = try await linkedSession(p)
        let other = try await insertSession(p, title: "Other")
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.loadSessions(projectID: p)
        await vm.asks.load(projectID: p)
        await vm.delete(session)
        await endWindow(vm)

        let ask = try XCTUnwrap(vm.asks.openAsks[p]?.first { $0.id == askID })
        XCTAssertNil(ask.sessionID, "the commit reloads the asks")
        XCTAssertEqual(vm.askSessionTitle(ask), OwnerAskStack.sessionDeletedTitle)

        let shown = await vm.showAsk(askID, projectID: p)

        XCTAssertTrue(shown)
        XCTAssertEqual(vm.asks.drawerAskIDs[p], askID)
        XCTAssertNil(vm.asks.drawerAsk(projectID: p)?.sessionID, "the page-edge drawer")
        XCTAssertFalse(vm.layout(projectID: p).visiblePanes.contains(.session(other.id)), "no other session put on screen")
        XCTAssertNil(vm.sessionErrors[p])
    }

    // MARK: - Quit (F3, F4)

    func testQuitWaitsForTheWindowsCommitInFlight() async throws {
        let p = try await workbench()
        let row = try await insertSession(p)
        let vm = makeVM()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        vm.commitSessionDeletes = { [pool] ids in
            didStart.yield()
            try await Task.sleep(for: .milliseconds(300))
            try await pool?.write { db in for id in ids { try TerminalSessionQueries.delete(db, id: id) } }
        }
        await vm.reload()
        await vm.delete(row)
        gate.open()
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()

        let finished = vm.commitPendingDeletesForQuit()

        XCTAssertTrue(finished)
        let gone = try await stored(row.id)
        XCTAssertNil(gone, "the quit waited for the window's write")
    }

    func testQuitIsBoundedWhenTheWriteHangs() async throws {
        let p = try await workbench()
        let row = try await insertSession(p)
        let vm = makeVM()
        let hang = DispatchSemaphore(value: 0)
        defer { hang.signal() }
        vm.commitSessionDeletes = { _ in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    hang.wait()
                    continuation.resume()
                }
            }
            throw WriteRefused()
        }
        vm.quitDeleteWait = 0.2
        await vm.reload()
        await vm.delete(row)

        let start = Date()
        let finished = vm.commitPendingDeletesForQuit()

        XCTAssertFalse(finished, "timed out")
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "bounded by quitDeleteWait")
        XCTAssertTrue(vm.pendingDeletes.batch.isEmpty)
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "listed again next launch")
    }

    func testQuitWriteFailureKeepsTheRow() async throws {
        let p = try await workbench()
        let row = try await insertSession(p)
        let vm = makeVM()
        vm.commitSessionDeletes = { _ in throw WriteRefused() }
        await vm.reload()
        await vm.delete(row)

        let finished = vm.commitPendingDeletesForQuit()

        XCTAssertTrue(finished, "the failed write finished")
        XCTAssertTrue(vm.pendingDeletes.batch.isEmpty)
        let kept = try await stored(row.id)
        XCTAssertNotNil(kept, "the safe side: the row survives")
    }

    // MARK: - The phone's slice (F7)

    func testHiddenIDsChangesAreReportedOnDeleteAndUndo() async throws {
        let p = try await workbench()
        let row = try await insertSession(p)
        let vm = makeVM()
        var reported: [Set<Int64>] = []
        vm.onPendingDeletesChanged = { reported.append($0) }
        await vm.reload()

        await vm.delete(row)
        await vm.undoPendingDeletes()

        XCTAssertEqual(reported, [[row.id], []])
    }
}
