import XCTest
import AppKit
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// A process whose `detach` runs a probe, so a test can see what the DB held
/// at the moment the center closed it.
@MainActor
private final class ProbedTerminalSession: TerminalSessionProcess {
    let view = NSView()
    let pid: pid_t = 0
    var onExit: ((Int32?) -> Void)?
    var bracketedPasteMode = true
    var onDetach: (() -> Void)?

    func start(_ launch: TerminalLaunch) {}
    func detach() { onDetach?() }
    func sendInput(_ bytes: [UInt8]) {}
}

@MainActor
private final class Counter {
    var value = 0
}

@MainActor
final class ProjectsViewModelSessionsTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!
    private var transcripts = true
    private var titleCalls: [Int64] = []
    private var titleResult: Result<TerminalTitleResult, Error> = .success(.init(title: "", written: false))
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelSessionsTests-\(UUID().uuidString)"))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt sessions \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        processes = []
        transcripts = true
        titleCalls = []
        titleResult = .success(.init(title: "", written: false))
        center = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { [weak self] _ in self?.transcripts ?? false }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM() -> ProjectsViewModel {
        let vm = ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: FakeCLIRunner()), defaults: defaults,
                                   terminalCenter: center)
        vm.titleService = { [weak self] id in
            guard let self else { throw CancellationError() }
            titleCalls.append(id)
            return try titleResult.get()
        }
        vm.now = { [weak self] in self?.clock ?? Date() }
        return vm
    }

    private func project(_ name: String = "acme") async throws -> Int64 {
        let path = folder.appendingPathComponent(name).path
        return try await pool.write { try TestDatabase.insertProject($0, name: name, folder: path) }
    }

    private var acme: String { folder.appendingPathComponent("acme").path }

    private func insertSession(_ new: TerminalSessionQueries.NewSession, closed: Bool = false) async throws -> TerminalSession {
        try await pool.write { db in
            let row = try TerminalSessionQueries.create(db, new)
            if closed { try TerminalSessionQueries.close(db, id: row.id) }
            return row
        }
    }

    private func projectWithFolder(_ name: String = "acme") async throws -> Int64 {
        let id = try await project(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        return id
    }

    private func rows(_ projectID: Int64) async throws -> [TerminalSession] {
        try await pool.read { try TerminalSessionQueries.fetchForProject($0, projectID: projectID) }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    // MARK: - Work on it

    func testWorkOnTwiceCreatesOneRowAndTheSecondCallFocusesIt() async throws {
        let p = try await projectWithFolder()
        let target = try await pool.write { try TestDatabase.insertProjectTarget($0, projectID: p, text: "Ship it") }
        let vm = makeVM()
        await vm.reload()

        await vm.workOn(targetID: target, targetText: "  Ship it  ")
        let other = try await insertSession(.init(projectID: p, kind: .shell, title: "zsh", folderPath: acme))
        center.focus(other.id)
        await vm.workOn(targetID: target, targetText: "Ship it")

        let all = try await rows(p).filter { $0.targetID == target }
        let row = try XCTUnwrap(all.first)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(row.title, "Ship it")
        XCTAssertEqual(row.titleSource, .auto)
        XCTAssertEqual(launches.count, 1, "the second call does not relaunch a running session")
        let uuid = try XCTUnwrap(row.claudeSessionID)
        XCTAssertEqual(launches.first?.args.last,
                       "exec claude --session-id \(uuid) '\(TerminalLaunch.workOnTargetPrompt(targetID: target))'")
        XCTAssertEqual(center.focusOrder.last, row.id)
        XCTAssertEqual(vm.layout(projectID: p).primary, .session(row.id))
    }

    func testWorkOnATargetWithOnlyAClosedSessionReopensAndResumesIt() async throws {
        let p = try await projectWithFolder()
        let target = try await pool.write { try TestDatabase.insertProjectTarget($0, projectID: p) }
        let closed = try await insertSession(.init(
            projectID: p, kind: .claude, title: "Feature", targetID: target,
            folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), closed: true)
        let vm = makeVM()

        await vm.workOn(targetID: target, targetText: "Feature")

        let after = try await rows(p)
        XCTAssertEqual(after.map(\.id), [closed.id], "no new row")
        XCTAssertFalse(after[0].isClosed)
        let uuid = try XCTUnwrap(closed.claudeSessionID)
        XCTAssertEqual(launches.map(\.args.last), ["exec claude --resume \(uuid)"])
    }

    // MARK: - Open / close / delete / rename

    func testOpenMarksTheSessionMostRecentlyActive() async throws {
        let p = try await projectWithFolder()
        let older = try await insertSession(.init(projectID: p, kind: .shell, title: "older", folderPath: acme))
        let newer = try await insertSession(.init(projectID: p, kind: .shell, title: "newer", folderPath: acme))
        try await pool.write { db in
            let sql = "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?"
            try db.execute(sql: sql, arguments: ["2020-01-01T00:00:00Z", older.id])
            try db.execute(sql: sql, arguments: ["2021-01-01T00:00:00Z", newer.id])
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p

        await vm.open(older)

        XCTAssertEqual(vm.sessions.first?.id, older.id)
        XCTAssertEqual(center.states[older.id], .running)
        XCTAssertEqual(center.focusOrder, [older.id])
    }

    func testDeleteOfARunningSessionClosesItBeforeTheRowGoesAndDropsItFromTheLayout() async throws {
        let p = try await projectWithFolder()
        var rowExistedAtDetach = false
        let probe = ProbedTerminalSession()
        center.makeProcess = { probe }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.newSession(projectID: p)
        let row = try XCTUnwrap(vm.sessions.first)
        XCTAssertEqual(vm.layout.primary, .session(row.id))
        probe.onDetach = { [pool] in
            rowExistedAtDetach = (try? pool?.read { try TerminalSessionQueries.fetch($0, id: row.id) }) != nil
        }

        await vm.delete(row)

        XCTAssertTrue(rowExistedAtDetach, "the process closed while the row still existed")
        XCTAssertNil(center.states[row.id])
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertEqual(vm.layout.visiblePanes, [.board])
        let stored = try await rows(p)
        XCTAssertTrue(stored.isEmpty)
    }

    func testCloseStopsTheProcessKeepsTheRowAndTriesATitle() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.newSession(projectID: p)
        let row = try XCTUnwrap(vm.sessions.first)

        await vm.close(row)

        XCTAssertNil(center.states[row.id])
        XCTAssertEqual(vm.sessions.map(\.id), [row.id])
        XCTAssertTrue(vm.sessions[0].isClosed)
        XCTAssertEqual(titleCalls, [row.id])
    }

    func testRenameToEmptyLeavesTheTitle() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.newSession(projectID: p)
        let row = try XCTUnwrap(vm.sessions.first)

        await vm.rename(row, to: "   ")
        XCTAssertEqual(vm.sessions.first?.title, row.title)
        XCTAssertEqual(vm.sessions.first?.titleSource, .auto)
        XCTAssertNil(vm.sessionErrors[p])

        await vm.rename(row, to: " Refactor ")
        XCTAssertEqual(vm.sessions.first?.title, "Refactor")
        XCTAssertEqual(vm.sessions.first?.titleSource, .user)
    }

    func testNewStandaloneShellIsNamedMechanicallyAndRunsTheLoginShell() async throws {
        let vm = makeVM()

        await vm.newStandalone(kind: .shell, folder: folder)

        let row = try XCTUnwrap(vm.standaloneSessions.first)
        XCTAssertNil(row.projectID)
        XCTAssertNil(row.claudeSessionID)
        XCTAssertEqual(row.title, TerminalSessionNaming.shell(shellPath: "/bin/zsh", folder: folder.path))
        XCTAssertEqual(launches.map(\.args), [["-l"]])
    }

    // MARK: - Resume failure / start fresh

    func testAResumeExitingNonZeroAtOnceOffersStartFreshWhichUsesANewID() async throws {
        let p = try await projectWithFolder()
        let row = try await insertSession(.init(
            projectID: p, kind: .claude, title: "s", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()

        await vm.open(row)
        clock += 1
        processes.last?.exit(1)
        XCTAssertEqual(vm.resumeFailed, [row.id])

        await vm.startFresh(row)

        XCTAssertTrue(vm.resumeFailed.isEmpty)
        let stored = try await pool.read { try TerminalSessionQueries.fetch($0, id: row.id) }
        let uuid = try XCTUnwrap(stored?.claudeSessionID)
        XCTAssertNotEqual(uuid, row.claudeSessionID)
        XCTAssertEqual(launches.last?.args.last, "exec claude --session-id \(uuid)")
    }

    func testAResumeEndingLaterOrCleanlyIsNotAFailure() async throws {
        let p = try await projectWithFolder()
        let row = try await insertSession(.init(
            projectID: p, kind: .claude, title: "s", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()

        await vm.open(row)
        clock += 10
        processes.last?.exit(1)
        await vm.open(row)
        processes.last?.exit(0)

        XCTAssertTrue(vm.resumeFailed.isEmpty)
    }

    // MARK: - Titles

    func testRefreshTitlesAsksOnlyForAutoClaudeSessionsAndStopsAfterFiveFailures() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.newSession(projectID: p)
        let auto = try XCTUnwrap(vm.sessions.first)
        await vm.newSession(projectID: p)
        let named = try XCTUnwrap(vm.sessions.first)
        await vm.rename(named, to: "Mine")
        titleCalls = []
        titleResult = .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))

        for _ in 0..<7 { await vm.refreshTitles() }

        XCTAssertEqual(titleCalls, Array(repeating: auto.id, count: TerminalSessionPolicy.maxTitleAttempts))
        XCTAssertNil(vm.sessionErrors[p], "a title failure is never shown")
    }

    func testANotYetTitledAnswerDoesNotUseTheAttemptBudget() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.newSession(projectID: p)
        titleCalls = []

        for _ in 0..<7 { await vm.refreshTitles() }

        XCTAssertEqual(titleCalls.count, 7)
    }

    func testSwitchingAwayTitlesTheSessionLeft() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p
        await vm.newSession(projectID: p)
        let first = try XCTUnwrap(vm.sessions.first)
        await vm.newSession(projectID: p)
        XCTAssertEqual(titleCalls, [first.id])

        await vm.open(first)
        XCTAssertEqual(titleCalls.count, 2)
        XCTAssertNotEqual(titleCalls.last, first.id)
    }

    func testTheTitlePollEndsOnceTheVMIsGone() async throws {
        var vm: ProjectsViewModel? = makeVM()
        let waits = Counter()
        vm?.titleSleep = { _ in
            waits.value += 1
            await Task.yield()
        }
        vm?.startTitleRefresh()
        let task = try XCTUnwrap(vm?.titleTask)
        while waits.value < 3 { await Task.yield() }
        weak var released = vm
        vm = nil
        // A loop that never ends would hang the test: the watchdog cancels it.
        let timedOut = Counter()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            timedOut.value = 1
            task.cancel()
        }

        await task.value
        watchdog.cancel()

        XCTAssertNil(released)
        XCTAssertEqual(timedOut.value, 0, "the loop ended on its own, not by the watchdog")
    }

    // MARK: - Errors

    func testASuccessfulLoadClearsTheLoadErrorButKeepsAnActionError() async throws {
        let p = try await projectWithFolder()
        let loose = try await pool.write { d -> Int64 in
            try d.execute(sql: "INSERT INTO targets (text) VALUES ('personal')")
            return d.lastInsertedRowID
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = p

        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions RENAME TO terminal_sessions_hidden") }
        await vm.loadSessions(projectID: p)
        XCTAssertNotNil(vm.sessionErrors[p])
        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions_hidden RENAME TO terminal_sessions") }
        await vm.reload()
        XCTAssertNil(vm.sessionErrors[p], "the poll's next good load clears it")

        await vm.workOn(targetID: loose, targetText: "personal")
        let actionError = try XCTUnwrap(vm.sessionErrors[p])
        await vm.reload()
        XCTAssertEqual(vm.sessionErrors[p], actionError, "a load does not wipe an action's error")
    }

    // MARK: - Navigation and layout

    /// House rule: a `newSession` for project A that finishes after the owner
    /// selected project B leaves B's sessions and layout alone.
    func testNewSessionFinishingAfterSwitchingProjectsLandsOnItsOwnProject() async throws {
        let a = try await projectWithFolder("a")
        let b = try await projectWithFolder("b")
        let vm = makeVM()
        await vm.reload()
        vm.selectedProjectID = a
        center.makeProcess = { [weak vm] in
            // Mid-flight: the row exists, the list and layout are not updated yet.
            vm?.selectedProjectID = b
            return FakeTerminalSession(pid: 0)
        }

        await vm.newSession(projectID: a)

        XCTAssertEqual(vm.selectedProjectID, b)
        XCTAssertTrue(vm.sessions.isEmpty)
        XCTAssertEqual(vm.layout, .default)
        let row = try XCTUnwrap(vm.terminalSessions[a]?.first)
        XCTAssertEqual(vm.layout(projectID: a).primary, .session(row.id))
    }

    func testLayoutIsPersistedPerProject() async throws {
        let a = try await project("a")
        let b = try await project("b")
        let vm = makeVM()
        await vm.reload()

        vm.selectedProjectID = a
        vm.layout.split(with: .documents)
        vm.selectedProjectID = b
        XCTAssertFalse(vm.layout.isSplit)
        vm.selectedProjectID = a
        XCTAssertTrue(vm.layout.isSplit)

        let relaunched = makeVM()
        relaunched.selectedProjectID = a
        XCTAssertEqual(relaunched.layout.visiblePanes, [.board, .documents])
    }
}
