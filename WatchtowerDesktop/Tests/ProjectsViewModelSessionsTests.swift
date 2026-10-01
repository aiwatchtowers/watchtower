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

    /// A double click on Work on it: two overlapping calls both see no
    /// session yet; the in-flight guard keeps it to one row and one launch.
    func testConcurrentWorkOnCreatesOneRow() async throws {
        let p = try await projectWithFolder()
        let target = try await pool.write { try TestDatabase.insertProjectTarget($0, projectID: p, text: "Ship it") }
        let vm = makeVM()
        await vm.reload()

        async let first: Void = vm.workOn(targetID: target, targetText: "Ship it")
        async let second: Void = vm.workOn(targetID: target, targetText: "Ship it")
        _ = await (first, second)

        let all = try await rows(p).filter { $0.targetID == target }
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(launches.count, 1)
    }

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

    /// Work on it from the board of a split keeps the board on screen, even
    /// when the board is the second pane; a title with shell or flag syntax
    /// names the row only, the command line keeps the fixed prompt.
    func testWorkOnFromASplitBoardKeepsTheBoardAndTheFixedPrompt() async throws {
        let p = try await projectWithFolder()
        let title = "Fix 'quotes'\n--dangerously-skip-permissions; rm -rf ~"
        let target = try await pool.write { try TestDatabase.insertProjectTarget($0, projectID: p, text: title) }
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.documents)
        vm.layout.split(with: .board)

        await vm.workOn(targetID: target, targetText: title)

        let all = try await rows(p)
        let row = try XCTUnwrap(all.first { $0.targetID == target })
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .board])
        XCTAssertEqual(row.title, title.trimmingCharacters(in: .whitespacesAndNewlines))
        let uuid = try XCTUnwrap(row.claudeSessionID)
        let command = "exec claude --session-id \(uuid) '\(TerminalLaunch.workOnTargetPrompt(targetID: target))'"
        XCTAssertEqual(launches.map(\.args), [["-l", "-c", command]])
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

    /// A transcript the check missed makes the relaunch a `--session-id` of
    /// the stored id, which Claude Code refuses at once: Start fresh too.
    func testARelaunchWithoutATranscriptExitingAtOnceOffersStartFresh() async throws {
        let p = try await projectWithFolder()
        let uuid = UUID().uuidString.lowercased()
        let row = try await insertSession(.init(
            projectID: p, kind: .claude, title: "s", folderPath: acme, claudeSessionID: uuid
        ))
        transcripts = false
        let vm = makeVM()

        await vm.open(row)
        XCTAssertEqual(launches.last?.args.last, "exec claude --session-id \(uuid)")
        clock += 1
        processes.last?.exit(1)

        XCTAssertEqual(vm.resumeFailed, [row.id])
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

        XCTAssertEqual(titleCalls.count, ProjectsViewModel.maxNotYetTitledPolls,
                       "a session with no owner message yet is left alone after a streak")
        let all = try await rows(p)
        let row = try XCTUnwrap(all.first)
        await vm.open(row)
        await vm.refreshTitles()
        XCTAssertEqual(titleCalls.count, ProjectsViewModel.maxNotYetTitledPolls + 1,
                       "switching back to the session asks again")
    }

    func testASessionWithoutATranscriptSpawnsNoTitleCall() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        transcripts = false
        await vm.newSession(projectID: p)
        titleCalls = []

        await vm.refreshTitles()

        XCTAssertTrue(titleCalls.isEmpty)
    }

    func testClaudeNotFoundIsNotAFailedResume() async throws {
        let p = try await projectWithFolder()
        let row = try await insertSession(.init(
            projectID: p, kind: .claude, title: "s", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()

        await vm.open(row)
        clock += 1
        processes.last?.exit(127)

        XCTAssertTrue(vm.resumeFailed.isEmpty)
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

    /// Spec §6: no process for a row that was not written.
    func testAFailedCreateStartsNoProcess() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()

        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions RENAME TO terminal_sessions_hidden") }
        await vm.newSession(projectID: p)
        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions_hidden RENAME TO terminal_sessions") }

        XCTAssertTrue(launches.isEmpty)
        XCTAssertTrue(center.liveIDs.isEmpty)
        XCTAssertNotNil(vm.sessionErrors[p])
    }

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

    // MARK: - Left panel

    func testSelectingAProjectDrillsInAndBackKeepsTheSelection() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()

        vm.drill(into: p)
        XCTAssertEqual(vm.drilledProjectID, p)
        XCTAssertEqual(vm.drilledProject?.id, p)
        XCTAssertTrue(launches.isEmpty, "drilling in starts nothing")

        vm.drilledProjectID = nil
        XCTAssertEqual(vm.selectedProjectID, p, "Back leaves the project on screen")
        vm.drill(into: p)
        XCTAssertEqual(vm.drilledProjectID, p, "clicking the selected project again drills back in")
    }

    func testPanelBoardAndDocumentsSetThePaneAndTheLayout() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showFromPanel(.documents)
        XCTAssertEqual(vm.layout.primary, .documents)
        XCTAssertEqual(vm.panelSelection, .documents)

        await vm.showFromPanel(.board)
        XCTAssertEqual(vm.panelSelection, .board)
    }

    func testPanelSessionClickShowsItAndCloseKeepsTheRowAndMovesToTheOtherLiveSession() async throws {
        let p = try await projectWithFolder()
        let first = try await insertSession(.init(
            projectID: p, kind: .claude, title: "first", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let second = try await insertSession(.init(
            projectID: p, kind: .claude, title: "second", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.board)

        await vm.showFromPanel(.session(first.id))
        await vm.showFromPanel(.session(second.id))
        XCTAssertEqual(vm.panelSelection, .session(second.id))
        XCTAssertEqual(center.liveIDs, [first.id, second.id], "switching keeps the other process running")

        await vm.close(second)

        let closed = try XCTUnwrap(vm.drilledSessions.first { $0.id == second.id }, "a closed session stays listed")
        XCTAssertTrue(closed.isClosed)
        XCTAssertFalse(vm.isLive(closed))
        XCTAssertEqual(vm.panelSelection, .session(first.id), "the pane falls back to the other live session")

        await vm.showFromPanel(.session(second.id))
        let reopened = try XCTUnwrap(vm.drilledSessions.first { $0.id == second.id })
        XCTAssertFalse(reopened.isClosed, "clicking a closed session reopens it")
        XCTAssertTrue(vm.isLive(reopened))
        XCTAssertEqual(vm.panelSelection, .session(second.id))
    }

    func testNewPanelSessionStartsOneInTheDrilledProjectAndShowsTheTerminal() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.documents)

        await vm.newPanelSession()

        let row = try XCTUnwrap(vm.drilledSessions.first)
        XCTAssertEqual(vm.panelSelection, .session(row.id))
        XCTAssertEqual(launches.count, 1)
    }

    func testStandaloneAndProjectSelectionExcludeEachOther() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.drilledProjectID = nil

        await vm.newStandalone(kind: .shell, folder: folder)
        let shell = try XCTUnwrap(vm.standaloneSessions.first)
        XCTAssertEqual(vm.selectedStandalone?.id, shell.id, "a new terminal goes on screen")
        XCTAssertNil(vm.selectedProjectID)

        vm.drill(into: p)
        XCTAssertNil(vm.selectedStandalone)

        await vm.close(shell)
        await vm.selectStandalone(shell)
        XCTAssertNil(vm.selectedProjectID)
        XCTAssertNil(vm.drilledProjectID)
        XCTAssertEqual(vm.selectedStandalone?.id, shell.id)
        XCTAssertEqual(vm.selectedStandalone?.isClosed, false, "selecting a closed terminal reopens it")
        XCTAssertTrue(vm.isLive(shell))

        await vm.delete(shell)
        XCTAssertNil(vm.selectedStandaloneID, "a deleted terminal leaves the page")
        XCTAssertTrue(vm.standaloneSessions.isEmpty)
    }

    /// A session opened from the panel stays on screen when it exits (its
    /// exit bar offers Restart / Start fresh), even with another one live.
    func testAnOpenedSessionThatExitsStaysShownOverAnotherLiveOne() async throws {
        let p = try await projectWithFolder()
        let live = try await insertSession(.init(
            projectID: p, kind: .claude, title: "live", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let failing = try await insertSession(.init(
            projectID: p, kind: .claude, title: "failing", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showFromPanel(.session(live.id))
        await vm.showFromPanel(.session(failing.id))
        processes.last?.exit(1)

        XCTAssertEqual(center.liveIDs, [live.id])
        XCTAssertEqual(vm.layout.primary, .session(failing.id), "the exited session keeps its pane")
        XCTAssertEqual(vm.panelSelection, .session(failing.id))
        XCTAssertEqual(vm.resumeFailed, [failing.id])

        // Send comments pastes into the live one and puts it on screen.
        vm.layout.show(.documents)
        vm.showTerminal(sessionID: live.id, projectID: p)
        XCTAssertEqual(vm.panelSelection, .session(live.id))
    }

    func testShowingAMissingSessionReportsIt() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showFromPanel(.session(999))

        XCTAssertEqual(vm.sessionErrors[p], "That session no longer exists.")
        XCTAssertTrue(launches.isEmpty)
    }

    func testARevealDrillsInAndReplacesAStandaloneTerminal() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        await vm.newStandalone(kind: .shell, folder: folder)
        XCTAssertNotNil(vm.selectedStandaloneID)

        vm.reveal(ProjectRoute(projectID: p, pane: .board))

        XCTAssertNil(vm.selectedStandaloneID)
        XCTAssertEqual(vm.drilledProjectID, p)
    }

    func testAProjectDeletedElsewhereLeavesTheSelectionAndThePanel() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [p]) }
        await vm.reload()

        XCTAssertNil(vm.selectedProjectID)
        XCTAssertNil(vm.drilledProjectID)
    }

    func testAStandaloneDeletedElsewhereLeavesThePage() async throws {
        let vm = makeVM()
        await vm.newStandalone(kind: .shell, folder: folder)
        let shell = try XCTUnwrap(vm.selectedStandalone)

        try await pool.write { try TerminalSessionQueries.delete($0, id: shell.id) }
        await vm.loadSessions(projectID: nil)

        XCTAssertNil(vm.selectedStandaloneID)
    }

    // MARK: - Main area (split / expand)

    private func liveSession(_ p: Int64, _ title: String) async throws -> TerminalSession {
        let row = try await insertSession(.init(
            projectID: p, kind: .claude, title: title, folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        return row
    }

    func testSplitPicksTheSecondPaneAndStartsNothing() async throws {
        let p = try await projectWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        vm.toggleSplit(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.board, .documents], "no live session: the other project view")
        vm.toggleSplit(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.board])

        await vm.showFromPanel(.session(row.id))
        vm.layout.show(.board)
        XCTAssertEqual(launches.count, 1)
        vm.toggleSplit(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.board, .session(row.id)], "the live session joins the board")

        vm.layout.unsplit()
        vm.layout.show(.session(row.id))
        vm.toggleSplit(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .board])
        XCTAssertEqual(launches.count, 1, "splitting launches nothing")
    }

    /// Send comments in a split: the session already beside the document
    /// stays where it is; a split without it replaces the other pane, never
    /// the document.
    func testSendCommentsInASplitNeverHidesTheDocument() async throws {
        let p = try await projectWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.showFromPanel(.session(row.id))
        vm.layout.split(with: .documents)
        let before = vm.layout

        vm.showTerminal(sessionID: row.id, projectID: p)
        XCTAssertEqual(vm.layout, before, "already visible: no pane switch")

        vm.layout.replace(.session(row.id), with: .board)
        vm.showTerminal(sessionID: row.id, projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .documents])
    }

    func testOpenTerminalFromADocumentKeepsItInTheSplit() async throws {
        let p = try await projectWithFolder()
        let fetched = try await pool.read { try ProjectQueries.fetch($0, id: p) }
        let project = try XCTUnwrap(fetched)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.split(with: .documents)

        await vm.openMostRecentSession(project: project, placement: .keeping(.documents))

        let row = try XCTUnwrap(vm.sessions.first)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .documents])
    }

    func testPanePickerOpensASessionInThatPane() async throws {
        let p = try await projectWithFolder()
        let closed = try await insertSession(.init(
            projectID: p, kind: .claude, title: "old", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), closed: true)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.split(with: .documents)

        await vm.showInPane(.board, item: .session(closed.id), projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(closed.id), .documents], "the picked pane, not the secondary")
        XCTAssertTrue(vm.isLive(try XCTUnwrap(vm.sessions.first { $0.id == closed.id })), "a closed session reopens")
        XCTAssertTrue(launches.last?.args.last?.contains("--resume") == true)

        await vm.showInPane(.documents, item: .board, projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(closed.id), .board])

        await vm.newSession(inPane: .session(closed.id), projectID: p)
        let fresh = try XCTUnwrap(vm.sessions.first { $0.id != closed.id })
        XCTAssertEqual(vm.layout.visiblePanes, [.session(fresh.id), .board])
        XCTAssertTrue(vm.isLive(try XCTUnwrap(vm.sessions.first { $0.id == closed.id })), "replacing a pane keeps its process")
    }

    func testClosingASplitSessionLeavesTheOtherPane() async throws {
        let p = try await projectWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.showFromPanel(.session(row.id))
        vm.layout.split(with: .board)
        vm.toggleExpand(.session(row.id), projectID: p)

        await vm.close(row)

        XCTAssertEqual(vm.layout.visiblePanes, [.board])
        XCTAssertFalse(vm.layout.isSplit)
    }

    func testExpandDividerAndClosePanePersist() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.toggleSplit(projectID: p)

        vm.toggleExpand(.documents, projectID: p)
        vm.setDividerFraction(0.95, projectID: p)
        let relaunched = makeVM()
        relaunched.selectedProjectID = p
        XCTAssertEqual(relaunched.layout.visiblePanes, [.documents])
        XCTAssertEqual(relaunched.layout.dividerFraction, 0.8)

        vm.toggleExpand(.documents, projectID: p)
        vm.closePane(.board, projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.documents])
    }

    /// A layout saved in an earlier run can name a session that is gone:
    /// the first list load drops it instead of showing an empty pane.
    func testALoadDropsASessionTheLayoutStillNames() async throws {
        let p = try await projectWithFolder()
        var stale = WorkspaceLayout.default
        stale.show(.session(999))
        stale.split(with: .documents)
        defaults.set(try JSONEncoder().encode(stale), forKey: WorkspaceLayout.key(projectID: p))
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.loadSessions(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.documents])
    }

    /// Resume / Restart / Start fresh inside an expanded pane keep it expanded.
    func testInPlaceButtonsKeepAnExpandedPane() async throws {
        let p = try await projectWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.showFromPanel(.session(row.id))
        vm.layout.split(with: .board)
        vm.toggleExpand(.session(row.id), projectID: p)
        processes.last?.exit(1)

        await vm.open(row, placement: .inPlace)
        XCTAssertEqual(vm.layout.expanded, .session(row.id))
        await vm.startFresh(row, placement: .inPlace)
        XCTAssertEqual(vm.layout.expanded, .session(row.id))
        XCTAssertTrue(vm.isLive(row))
    }

    /// A pane picked from a menu that left the layout while the session
    /// started still puts the session on screen.
    func testReplacingAGoneSlotFallsBackToShow() async throws {
        let p = try await projectWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showInPane(.documents, item: .session(row.id), projectID: p)

        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id)])
    }

    /// A terminal deep link to a project not loaded yet, nothing live (an
    /// app restart): its most recent open session goes on screen, unstarted.
    func testTerminalDeepLinkShowsTheMostRecentOpenSession() async throws {
        let p = try await projectWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()

        await vm.revealTerminal(projectID: p)

        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(row.id)])
        XCTAssertTrue(launches.isEmpty, "a deep link starts nothing")
    }

    /// Two overlapping reads, the older one finishing last: the newer list
    /// stays, and a session placed between the two starts is not pruned.
    func testAnOlderReadFinishingLastNeitherHidesTheNewListNorPrunesTheLayout() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        let row = try await liveSession(p, "one")
        var gates: [CheckedContinuation<Void, Never>] = []
        var results: [[TerminalSession]] = [[], [row]]
        vm.readProjectSessions = { _ in
            let rows = results.removeFirst()
            await withCheckedContinuation { gates.append($0) }
            return rows
        }

        let older = Task { await vm.loadSessions(projectID: p) }
        try await yieldUntil { gates.count >= 1 }
        var placed = vm.layout(projectID: p)
        placed.show(.session(row.id))
        vm.setLayout(placed, projectID: p)
        let newer = Task { await vm.loadSessions(projectID: p) }
        try await yieldUntil { gates.count >= 2 }

        gates[1].resume()
        let newerApplied = await newer.value
        gates[0].resume()
        let olderApplied = await older.value

        XCTAssertTrue(newerApplied)
        XCTAssertTrue(olderApplied, "the list already reflects a newer read")
        XCTAssertEqual(vm.terminalSessions[p]?.map(\.id), [row.id], "the older, emptier read is dropped")
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(row.id)])
    }

    /// The older read finishing first is applied (the caller sees its own
    /// rows) but does not prune: a newer read is still in flight.
    func testAnOlderReadFinishingFirstIsAppliedWithoutPruning() async throws {
        let p = try await projectWithFolder()
        let vm = makeVM()
        let row = try await liveSession(p, "one")
        var gates: [CheckedContinuation<Void, Never>] = []
        var results: [[TerminalSession]] = [[], [row]]
        vm.readProjectSessions = { _ in
            let rows = results.removeFirst()
            await withCheckedContinuation { gates.append($0) }
            return rows
        }

        let older = Task { await vm.loadSessions(projectID: p) }
        try await yieldUntil { gates.count >= 1 }
        var placed = vm.layout(projectID: p)
        placed.show(.session(row.id))
        vm.setLayout(placed, projectID: p)
        let newer = Task { await vm.loadSessions(projectID: p) }
        try await yieldUntil { gates.count >= 2 }

        gates[0].resume()
        let olderApplied = await older.value
        XCTAssertTrue(olderApplied)
        XCTAssertEqual(vm.terminalSessions[p]?.count, 0)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(row.id)], "only the latest read prunes")

        gates[1].resume()
        _ = await newer.value
        XCTAssertEqual(vm.terminalSessions[p]?.map(\.id), [row.id])
    }

    /// Bounded: a regression that never reaches the gate fails, not hangs.
    private func yieldUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within 5 s", file: file, line: line)
                throw CancellationError()
            }
            await Task.yield()
        }
    }
}
