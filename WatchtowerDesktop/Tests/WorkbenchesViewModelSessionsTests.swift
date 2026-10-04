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
    var onOwnerInput: (([UInt8]) -> Void)?
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
final class WorkbenchesViewModelSessionsTests: XCTestCase {
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
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelSessionsTests-\(UUID().uuidString)"))
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

    private func makeVM() -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
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
        return try await pool.write { try TestDatabase.insertWorkbench($0, name: name, folder: path) }
    }

    private var acme: String { folder.appendingPathComponent("acme").path }

    /// `legacyClosed` sets `closed_at` the way the removed Close action did:
    /// such a row must behave as an ordinary session that is not running.
    private func insertSession(
        _ new: TerminalSessionQueries.NewSession, legacyClosed: Bool = false
    ) async throws -> TerminalSession {
        try await pool.write { db in
            let row = try TerminalSessionQueries.create(db, new)
            if legacyClosed {
                try db.execute(sql: "UPDATE terminal_sessions SET closed_at = '2026-09-30T12:00:00Z' WHERE id = ?",
                               arguments: [row.id])
            }
            return row
        }
    }

    private func workbenchWithFolder(_ name: String = "acme") async throws -> Int64 {
        let id = try await project(name)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
        return id
    }

    private func rows(_ projectID: Int64) async throws -> [TerminalSession] {
        try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: projectID) }
    }

    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    // MARK: - Work on it

    /// A double click on Work on it: two overlapping calls both see no
    /// session yet; the in-flight guard keeps it to one row and one launch.
    func testConcurrentWorkOnCreatesOneRow() async throws {
        let p = try await workbenchWithFolder()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Ship it") }
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
        let p = try await workbenchWithFolder()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Ship it") }
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
                       "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'")
        XCTAssertEqual(launches.first?.environment.last,
                       "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnTargetPrompt(targetID: target, vocabulary: .current))")
        XCTAssertEqual(center.focusOrder.last, row.id)
        XCTAssertEqual(vm.layout(projectID: p).primary, .session(row.id))
    }

    /// A folder set up before the Workbench rename has only the old skill
    /// (spec 2026-10-02 §5.3): once `integrate status` says so, "Work on it"
    /// names that skill; before the status is read, the new one.
    func testWorkOnNamesTheLegacySkillOnceTheStatusSaysSo() async throws {
        let p = try await workbenchWithFolder()
        let first = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "One") }
        let second = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Two") }
        let status = #"{"skill":"missing","hook":true,"stop_hook":true,"mcp":true,"legacy":true,"legacy_skill":"unchanged"}"#
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner(stdout: Data(status.utf8))),
                                      defaults: defaults, terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        await vm.reload()

        XCTAssertEqual(vm.vocabulary(projectID: p), .current, "unknown status: the new name")
        await vm.workOn(targetID: first, targetText: "One")
        XCTAssertEqual(launches.last?.environment.last, "WATCHTOWER_FIRST_PROMPT=Work on target #\(first) using the watchtower-workbench skill.")

        await vm.refreshInstallStatus(projectID: p)
        XCTAssertEqual(vm.vocabulary(projectID: p), .legacy)
        await vm.workOn(targetID: second, targetText: "Two")
        XCTAssertEqual(launches.last?.environment.last, "WATCHTOWER_FIRST_PROMPT=Work on target #\(second) using the watchtower-project skill.")
    }

    /// Board #160: `/clear` moved Claude Code to a new session id, which the
    /// project's SessionStart hook stored on the row from another process.
    /// Opening it from a list loaded before that resumes the new id, not the
    /// pre-clear conversation, and the launch names its row for the hook.
    func testOpenResumesTheSessionIDTheHookStored() async throws {
        let p = try await workbenchWithFolder()
        let stale = try await insertSession(.init(
            projectID: p, kind: .claude, title: "s", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let cleared = UUID().uuidString.lowercased()
        try await pool.write {
            try $0.execute(sql: "UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?",
                           arguments: [cleared, stale.id])
        }
        let vm = makeVM()

        await vm.open(stale)

        XCTAssertEqual(launches.map(\.args.last), ["exec claude --resume \(cleared)"])
        XCTAssertEqual(launches.first?.environment, ["\(TerminalLaunch.sessionRowEnv)=\(stale.id)"])
    }

    func testWorkOnATargetWithALegacyClosedSessionResumesIt() async throws {
        let p = try await workbenchWithFolder()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p) }
        let closed = try await insertSession(.init(
            projectID: p, kind: .claude, title: "Feature", targetID: target,
            folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), legacyClosed: true)
        let vm = makeVM()

        await vm.workOn(targetID: target, targetText: "Feature")

        let after = try await rows(p)
        XCTAssertEqual(after.map(\.id), [closed.id], "no new row")
        let uuid = try XCTUnwrap(closed.claudeSessionID)
        XCTAssertEqual(launches.map(\.args.last), ["exec claude --resume \(uuid)"])
    }

    /// Work on it from the board of a split keeps the board on screen, even
    /// when the board is the second pane; a title with shell or flag syntax
    /// names the row only, the command line keeps the fixed prompt.
    func testWorkOnFromASplitBoardKeepsTheBoardAndTheFixedPrompt() async throws {
        let p = try await workbenchWithFolder()
        let title = "Fix 'quotes'\n--dangerously-skip-permissions; rm -rf ~"
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: title) }
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.files)
        vm.layout.split(with: .board)

        await vm.workOn(targetID: target, targetText: title)

        let all = try await rows(p)
        let row = try XCTUnwrap(all.first { $0.targetID == target })
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .board])
        XCTAssertEqual(row.title, title.trimmingCharacters(in: .whitespacesAndNewlines))
        let uuid = try XCTUnwrap(row.claudeSessionID)
        let command = "exec /bin/sh -c 'exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"'"
        XCTAssertEqual(launches.map(\.args), [["-l", "-c", command]])
        XCTAssertEqual(launches.first?.environment.last,
                       "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.workOnTargetPrompt(targetID: target, vocabulary: .current))")
    }

    /// The existing-session branch keeps the board in a split too, also
    /// out of an expanded board; a single pane switches to the session.
    func testWorkOnAnExistingSessionKeepsTheBoardInASplitAndSwitchesASinglePane() async throws {
        let p = try await workbenchWithFolder()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p) }
        let existing = try await insertSession(.init(
            projectID: p, kind: .claude, title: "Feature", targetID: target,
            folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.files)
        vm.layout.split(with: .board)
        vm.toggleExpand(.board, projectID: p)

        await vm.workOn(targetID: target, targetText: "Feature", projectID: p)

        XCTAssertEqual(vm.layout.visiblePanes, [.session(existing.id), .board])
        XCTAssertNil(vm.layout.expanded)
        let after = try await rows(p)
        XCTAssertEqual(after.map(\.id), [existing.id], "no new row")

        vm.layout.unsplit()
        vm.layout.show(.board)
        await vm.workOn(targetID: target, targetText: "Feature", projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(existing.id)], "a single pane switches to the session")
    }

    /// A read error belongs to the target's own project, not to whatever is
    /// selected when it lands.
    func testWorkOnErrorLandsOnTheTargetsProject() async throws {
        let a = try await workbenchWithFolder("a")
        let b = try await workbenchWithFolder("b")
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = b

        await vm.workOn(targetID: 9_999, targetText: "gone", projectID: a)

        XCTAssertNotNil(vm.sessionErrors[a])
        XCTAssertNil(vm.sessionErrors[b])
    }

    // MARK: - Open / delete / rename

    func testOpenMarksTheSessionMostRecentlyActive() async throws {
        let p = try await workbenchWithFolder()
        let older = try await insertSession(.init(projectID: p, kind: .shell, title: "older", folderPath: acme))
        let newer = try await insertSession(.init(projectID: p, kind: .shell, title: "newer", folderPath: acme))
        try await pool.write { db in
            let sql = "UPDATE terminal_sessions SET last_active_at = ? WHERE id = ?"
            try db.execute(sql: sql, arguments: ["2020-01-01T00:00:00Z", older.id])
            try db.execute(sql: sql, arguments: ["2021-01-01T00:00:00Z", newer.id])
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p

        await vm.open(older)

        XCTAssertEqual(vm.sessions.first?.id, older.id)
        XCTAssertEqual(center.states[older.id], .running)
        XCTAssertEqual(center.focusOrder, [older.id])
    }

    func testDeleteOfARunningSessionClosesItBeforeTheRowGoesAndDropsItFromTheLayout() async throws {
        let p = try await workbenchWithFolder()
        var rowExistedAtDetach = false
        let probe = ProbedTerminalSession()
        center.makeProcess = { probe }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
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

    /// "Open terminal" picks a row closed by an older build like any other:
    /// the most recent session resumes, no new one is started.
    func testOpenMostRecentResumesALegacyClosedSession() async throws {
        let p = try await workbenchWithFolder()
        let closed = try await insertSession(.init(
            projectID: p, kind: .claude, title: "Feature",
            folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), legacyClosed: true)
        let fetched = try await pool.read { try WorkbenchQueries.fetch($0, id: p) }
        let project = try XCTUnwrap(fetched)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.openMostRecentSession(project: project)

        let after = try await rows(p)
        XCTAssertEqual(after.map(\.id), [closed.id], "no new row")
        XCTAssertEqual(launches.map(\.args.last), ["exec claude --resume \(try XCTUnwrap(closed.claudeSessionID))"])
        XCTAssertEqual(vm.layout.primary, .session(closed.id))
    }

    func testRenameToEmptyLeavesTheTitle() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
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
        let p = try await workbenchWithFolder()
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
        let p = try await workbenchWithFolder()
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
        let p = try await workbenchWithFolder()
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
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
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
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.newSession(projectID: p)
        titleCalls = []

        for _ in 0..<7 { await vm.refreshTitles() }

        XCTAssertEqual(titleCalls.count, WorkbenchesViewModel.maxNotYetTitledPolls,
                       "a session with no owner message yet is left alone after a streak")
        let all = try await rows(p)
        let row = try XCTUnwrap(all.first)
        await vm.open(row)
        await vm.refreshTitles()
        XCTAssertEqual(titleCalls.count, WorkbenchesViewModel.maxNotYetTitledPolls + 1,
                       "switching back to the session asks again")
    }

    func testASessionWithoutATranscriptSpawnsNoTitleCall() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        transcripts = false
        await vm.newSession(projectID: p)
        titleCalls = []

        await vm.refreshTitles()

        XCTAssertTrue(titleCalls.isEmpty)
    }

    func testClaudeNotFoundIsNotAFailedResume() async throws {
        let p = try await workbenchWithFolder()
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
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p
        await vm.newSession(projectID: p)
        let first = try XCTUnwrap(vm.sessions.first)
        await vm.newSession(projectID: p)
        XCTAssertEqual(titleCalls, [first.id])

        await vm.open(first)
        XCTAssertEqual(titleCalls.count, 2)
        XCTAssertNotEqual(titleCalls.last, first.id)
    }

    func testTheTitlePollEndsOnceTheVMIsGone() async throws {
        var vm: WorkbenchesViewModel? = makeVM()
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
        let p = try await workbenchWithFolder()
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
        let p = try await workbenchWithFolder()
        let loose = try await pool.write { d -> Int64 in
            try d.execute(sql: "INSERT INTO targets (text, period_start, period_end) VALUES ('personal', date('now'), date('now'))")
            return d.lastInsertedRowID
        }
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = p

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
        let a = try await workbenchWithFolder("a")
        let b = try await workbenchWithFolder("b")
        let vm = makeVM()
        await vm.reload()
        vm.selectedWorkbenchID = a
        center.makeProcess = { [weak vm] in
            // Mid-flight: the row exists, the list and layout are not updated yet.
            vm?.selectedWorkbenchID = b
            return FakeTerminalSession(pid: 0)
        }

        await vm.newSession(projectID: a)

        XCTAssertEqual(vm.selectedWorkbenchID, b)
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

        vm.selectedWorkbenchID = a
        vm.layout.split(with: .files)
        vm.selectedWorkbenchID = b
        XCTAssertFalse(vm.layout.isSplit)
        vm.selectedWorkbenchID = a
        XCTAssertTrue(vm.layout.isSplit)

        let relaunched = makeVM()
        relaunched.selectedWorkbenchID = a
        XCTAssertEqual(relaunched.layout.visiblePanes, [.board, .files])
    }

    // MARK: - Left panel

    func testSelectingAProjectDrillsInAndBackKeepsTheSelection() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()

        vm.drill(into: p)
        XCTAssertEqual(vm.drilledWorkbenchID, p)
        XCTAssertEqual(vm.drilledWorkbench?.id, p)
        XCTAssertTrue(launches.isEmpty, "drilling in starts nothing")

        vm.drilledWorkbenchID = nil
        XCTAssertEqual(vm.selectedWorkbenchID, p, "Back leaves the project on screen")
        vm.drill(into: p)
        XCTAssertEqual(vm.drilledWorkbenchID, p, "clicking the selected project again drills back in")
    }

    /// A split of a session and the board highlights the session, whichever
    /// slot holds it.
    func testPanelHighlightsTheVisibleSessionInASplit() async throws {
        let p = try await workbenchWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.showSession(id: row.id)
        vm.layout.split(with: .board)
        XCTAssertEqual(vm.panelSelection, .session(row.id))
        vm.toggleExpand(.board, projectID: p)
        XCTAssertNil(vm.panelSelection, "the expanded board hides the session")
        vm.layout.unsplit()
        vm.layout.show(.files)
        XCTAssertNil(vm.panelSelection, "the panel lists sessions only")
    }

    /// A panel click shows a session and starts it if not running — a row
    /// closed by an older build included — keeping the other one running.
    func testPanelSessionClickShowsAndStartsItAndKeepsTheOtherRunning() async throws {
        let p = try await workbenchWithFolder()
        let first = try await insertSession(.init(
            projectID: p, kind: .claude, title: "first", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let second = try await insertSession(.init(
            projectID: p, kind: .claude, title: "second", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), legacyClosed: true)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.board)

        await vm.showSession(id: first.id)
        await vm.showSession(id: second.id)

        XCTAssertNotNil(vm.drilledSessions.first { $0.id == second.id }, "a legacy closed session is listed")
        XCTAssertEqual(vm.panelSelection, .session(second.id))
        XCTAssertEqual(center.liveIDs, [first.id, second.id], "switching keeps the other process running")
        XCTAssertEqual(launches.last?.args.last, "exec claude --resume \(try XCTUnwrap(second.claudeSessionID))")
    }

    func testNewPanelSessionStartsOneInTheDrilledProjectAndShowsTheTerminal() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.files)

        await vm.newSessionOnPage()

        let row = try XCTUnwrap(vm.drilledSessions.first)
        XCTAssertEqual(vm.panelSelection, .session(row.id))
        XCTAssertEqual(launches.count, 1)
    }

    func testStandaloneAndProjectSelectionExcludeEachOther() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.drilledWorkbenchID = nil

        await vm.newStandalone(kind: .shell, folder: folder)
        let shell = try XCTUnwrap(vm.standaloneSessions.first)
        XCTAssertEqual(vm.selectedStandalone?.id, shell.id, "a new terminal goes on screen")
        XCTAssertNil(vm.selectedWorkbenchID)

        vm.drill(into: p)
        XCTAssertNil(vm.selectedStandalone)

        await vm.selectStandalone(shell)
        XCTAssertNil(vm.selectedWorkbenchID)
        XCTAssertNil(vm.drilledWorkbenchID)
        XCTAssertEqual(vm.selectedStandalone?.id, shell.id)

        await vm.delete(shell)
        XCTAssertNil(vm.selectedStandaloneID, "a deleted terminal leaves the page")
        XCTAssertTrue(vm.standaloneSessions.isEmpty)
    }

    /// A standalone terminal closed by an older build is listed and, once
    /// selected, starts like any terminal that is not running.
    func testSelectingALegacyClosedStandaloneTerminalStartsIt() async throws {
        let shell = try await insertSession(
            .init(projectID: nil, kind: .shell, title: "zsh", folderPath: folder.path), legacyClosed: true
        )
        let vm = makeVM()
        await vm.reload()
        await vm.loadSessions(projectID: nil)
        XCTAssertEqual(vm.standaloneSessions.map(\.id), [shell.id], "a legacy closed terminal is listed")
        XCTAssertFalse(vm.sessionState(shell).live)

        await vm.selectStandalone(shell)

        XCTAssertEqual(vm.selectedStandalone?.id, shell.id)
        XCTAssertTrue(vm.sessionState(shell).live)
        XCTAssertEqual(launches.count, 1)
    }

    /// A session opened from the panel stays on screen when it exits (its
    /// exit bar offers Restart / Start fresh), even with another one live.
    func testAnOpenedSessionThatExitsStaysShownOverAnotherLiveOne() async throws {
        let p = try await workbenchWithFolder()
        let live = try await insertSession(.init(
            projectID: p, kind: .claude, title: "live", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let failing = try await insertSession(.init(
            projectID: p, kind: .claude, title: "failing", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showSession(id: live.id)
        await vm.showSession(id: failing.id)
        processes.last?.exit(1)

        XCTAssertEqual(center.liveIDs, [live.id])
        XCTAssertEqual(vm.layout.primary, .session(failing.id), "the exited session keeps its pane")
        XCTAssertEqual(vm.panelSelection, .session(failing.id))
        XCTAssertEqual(vm.resumeFailed, [failing.id])
    }

    func testShowingAMissingSessionReportsIt() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showSession(id: 999)

        XCTAssertEqual(vm.sessionErrors[p], "That session no longer exists.")
        XCTAssertTrue(launches.isEmpty)
    }

    /// `touch` is unchecked: the fetch in the same write is what reports a
    /// row deleted elsewhere, for Open and Start fresh alike — no process
    /// starts and the pane leaves the layout.
    func testOpeningASessionDeletedElsewhereReportsItAndStartsNothing() async throws {
        let p = try await workbenchWithFolder()
        let row = try await liveSession(p, "gone")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.show(.session(row.id))
        _ = try await pool.write { try TerminalSessionQueries.delete($0, id: row.id) }

        await vm.open(row)
        XCTAssertEqual(vm.sessionErrors[p], "Could not open the session: Terminal session \(row.id) no longer exists.")
        XCTAssertFalse(vm.layout.sessionIDs.contains(row.id))

        vm.layout.show(.session(row.id))
        await vm.startFresh(row)
        XCTAssertEqual(vm.sessionErrors[p],
                       "Could not start the session fresh: Terminal session \(row.id) no longer exists.")
        XCTAssertFalse(vm.layout.sessionIDs.contains(row.id))
        XCTAssertTrue(launches.isEmpty)
    }

    func testARevealDrillsInAndReplacesAStandaloneTerminal() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        await vm.newStandalone(kind: .shell, folder: folder)
        XCTAssertNotNil(vm.selectedStandaloneID)

        vm.reveal(WorkbenchRoute(projectID: p, pane: .board))

        XCTAssertNil(vm.selectedStandaloneID)
        XCTAssertEqual(vm.drilledWorkbenchID, p)
    }

    func testAProjectDeletedElsewhereLeavesTheSelectionAndThePanel() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [p]) }
        await vm.reload()

        XCTAssertNil(vm.selectedWorkbenchID)
        XCTAssertNil(vm.drilledWorkbenchID)
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
        let p = try await workbenchWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        vm.toggleSplit(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.board, .files], "no live session: the other project view")
        vm.toggleSplit(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.board])

        await vm.showSession(id: row.id)
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

    func testOpenTerminalFromTheFilesPaneKeepsItInTheSplit() async throws {
        let p = try await workbenchWithFolder()
        let fetched = try await pool.read { try WorkbenchQueries.fetch($0, id: p) }
        let project = try XCTUnwrap(fetched)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.split(with: .files)

        await vm.openMostRecentSession(project: project, placement: .keeping(.files))

        let row = try XCTUnwrap(vm.sessions.first)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .files])
    }

    func testPanePickerOpensASessionInThatPane() async throws {
        let p = try await workbenchWithFolder()
        let closed = try await insertSession(.init(
            projectID: p, kind: .claude, title: "old", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), legacyClosed: true)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.split(with: .files)

        await vm.showInPane(.board, item: .session(closed.id), projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(closed.id), .files], "the picked pane, not the secondary")
        XCTAssertTrue(vm.sessionState(try XCTUnwrap(vm.sessions.first { $0.id == closed.id })).live,
                      "a session closed by an older build resumes like any not running one")
        XCTAssertTrue(launches.last?.args.last?.contains("--resume") == true)

        await vm.showInPane(.files, item: .board, projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(closed.id), .board])

        await vm.newSession(inPane: .session(closed.id), projectID: p)
        let fresh = try XCTUnwrap(vm.sessions.first { $0.id != closed.id })
        XCTAssertEqual(vm.layout.visiblePanes, [.session(fresh.id), .board])
        XCTAssertTrue(vm.sessionState(try XCTUnwrap(vm.sessions.first { $0.id == closed.id })).live, "replacing a pane keeps its process")
    }

    /// The page header's buttons: Board / Files swap the pane beside the
    /// terminal; Terminal brings back a session already in a slot, or resumes
    /// the most recent one next to the view on screen.
    func testHeaderViewButtonsKeepTheTerminalAndPickASession() async throws {
        let p = try await workbenchWithFolder()
        let fetched = try await pool.read { try WorkbenchQueries.fetch($0, id: p) }
        let project = try XCTUnwrap(fetched)
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.board])

        await vm.showView(.terminal, project: project)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id)], "a single pane switches to the most recent session")
        XCTAssertEqual(launches.count, 1, "it resumes")

        vm.toggleSplit(projectID: p)
        await vm.showView(.files, project: project)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .files])
        await vm.showView(.board, project: project)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .board])

        vm.toggleExpand(.board, projectID: p)
        await vm.showView(.terminal, project: project)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id), .board], "the session in the split comes back")
        XCTAssertEqual(launches.count, 1, "nothing starts again")

        vm.hideView(.board, projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id)])
        XCTAssertEqual(vm.layout(projectID: p), WorkspaceLayout.decode(defaults.data(forKey: WorkspaceLayout.key(workbenchID: p))),
                       "the layout is persisted")
    }

    /// The header's session menu in a single pane: another session replaces
    /// the terminal on screen, "New session" starts one there.
    func testHeaderSessionMenuSwitchesTheSinglePaneSession() async throws {
        let p = try await workbenchWithFolder()
        let one = try await liveSession(p, "one")
        let two = try await liveSession(p, "two")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.showSession(id: one.id)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(one.id)])

        await vm.showInPane(vm.layout.terminalSlot, item: .session(two.id), projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.session(two.id)])

        await vm.newSession(inPane: vm.layout.terminalSlot, projectID: p)
        let fresh = try XCTUnwrap(vm.sessions.first { $0.id != one.id && $0.id != two.id })
        XCTAssertEqual(vm.layout.visiblePanes, [.session(fresh.id)])
    }

    func testHeaderTerminalButtonStartsASessionWhenTheProjectHasNone() async throws {
        let p = try await workbenchWithFolder()
        let fetched = try await pool.read { try WorkbenchQueries.fetch($0, id: p) }
        let project = try XCTUnwrap(fetched)
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.layout.split(with: .files)

        await vm.showView(.terminal, project: project)

        let row = try XCTUnwrap(vm.sessions.first)
        XCTAssertEqual(vm.layout.visiblePanes, [.board, .session(row.id)], "it keeps the first view, replaces the second")
        XCTAssertEqual(launches.count, 1)
    }

    func testExpandDividerAndClosePanePersist() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        vm.toggleSplit(projectID: p)

        vm.toggleExpand(.files, projectID: p)
        vm.setDividerFraction(0.95, projectID: p)
        let relaunched = makeVM()
        relaunched.selectedWorkbenchID = p
        XCTAssertEqual(relaunched.layout.visiblePanes, [.files])
        XCTAssertEqual(relaunched.layout.dividerFraction, 0.8)

        vm.toggleExpand(.files, projectID: p)
        vm.closePane(.board, projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.files])
    }

    /// A layout saved in an earlier run can name a session that is gone:
    /// the first list load drops it instead of showing an empty pane.
    func testALoadDropsASessionTheLayoutStillNames() async throws {
        let p = try await workbenchWithFolder()
        var stale = WorkspaceLayout.default
        stale.show(.session(999))
        stale.split(with: .files)
        defaults.set(try JSONEncoder().encode(stale), forKey: WorkspaceLayout.key(workbenchID: p))
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.loadSessions(projectID: p)
        XCTAssertEqual(vm.layout.visiblePanes, [.files])
    }

    /// Resume / Restart / Start fresh inside an expanded pane keep it expanded.
    func testInPlaceButtonsKeepAnExpandedPane() async throws {
        let p = try await workbenchWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.showSession(id: row.id)
        vm.layout.split(with: .board)
        vm.toggleExpand(.session(row.id), projectID: p)
        processes.last?.exit(1)

        await vm.open(row, placement: .inPlace)
        XCTAssertEqual(vm.layout.expanded, .session(row.id))
        await vm.startFresh(row, placement: .inPlace)
        XCTAssertEqual(vm.layout.expanded, .session(row.id))
        XCTAssertTrue(vm.sessionState(row).live)
    }

    /// A pane picked from a menu that left the layout while the session
    /// started still puts the session on screen.
    func testReplacingAGoneSlotFallsBackToShow() async throws {
        let p = try await workbenchWithFolder()
        let row = try await liveSession(p, "one")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)

        await vm.showInPane(.files, item: .session(row.id), projectID: p)

        XCTAssertEqual(vm.layout.visiblePanes, [.session(row.id)])
    }

    /// A terminal deep link to a project not loaded yet, nothing live (an
    /// app restart): its most recent session goes on screen, unstarted — a
    /// row closed by an older build included.
    func testTerminalDeepLinkShowsTheMostRecentSession() async throws {
        let p = try await workbenchWithFolder()
        _ = try await liveSession(p, "older")
        let row = try await insertSession(.init(
            projectID: p, kind: .claude, title: "one", folderPath: acme, claudeSessionID: UUID().uuidString.lowercased()
        ), legacyClosed: true)
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = '2099-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [row.id])
        }
        let vm = makeVM()

        await vm.revealTerminal(projectID: p)

        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(row.id)])
        XCTAssertTrue(launches.isEmpty, "a deep link starts nothing")
    }

    /// A session notice's click (board #312): the deep link's subject is
    /// that session, drilled into and on screen — not the live-else-latest
    /// one — also when it was created after the last read.
    func testTerminalDeepLinkWithASubjectShowsThatSession() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        let latest = try await liveSession(p, "latest")
        await vm.open(latest)
        let waiting = try await liveSession(p, "waiting")
        await vm.open(waiting)
        await vm.open(latest)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(latest.id)])
        let later = try await liveSession(p, "created since the read")
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = '2000-01-01T00:00:00Z' WHERE id = ?",
                           arguments: [later.id])
        }
        let launchesBefore = launches.count

        await vm.revealTerminal(projectID: p, sessionID: waiting.id)
        XCTAssertEqual(vm.drilledWorkbenchID, p)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(waiting.id)])
        XCTAssertEqual(launches.count, launchesBefore, "a live session is shown, not started again")

        await vm.revealTerminal(projectID: p, sessionID: later.id)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(later.id)], "a session missing from the last read is found too")
    }

    /// The banner click goes through `reveal(_:)`: its `subjectId` reaches
    /// the terminal reveal, so the waiting session is shown, not the latest.
    func testTerminalRouteWithASubjectRevealsThatSession() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        let latest = try await liveSession(p, "latest")
        await vm.open(latest)
        let waiting = try await liveSession(p, "waiting")
        await vm.open(waiting)
        await vm.open(latest)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(latest.id)])

        vm.reveal(WorkbenchRoute(projectID: p, pane: .terminal, subjectID: waiting.id))

        let deadline = ContinuousClock.now + .seconds(3)
        while vm.layout(projectID: p).visiblePanes != [.session(waiting.id)], ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(waiting.id)])
    }

    /// A stale banner (the session stopped since it was posted) shows that
    /// session without starting it: a click never launches an agent.
    func testTerminalDeepLinkToAStoppedSessionStartsNothing() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        let live = try await liveSession(p, "live")
        await vm.open(live)
        let stopped = try await liveSession(p, "stopped")
        await vm.open(stopped)
        processes.last?.exit(0)
        await vm.open(live)
        XCTAssertFalse(vm.sessionState(stopped).live)
        let launchesBefore = launches.count

        await vm.revealTerminal(projectID: p, sessionID: stopped.id)

        XCTAssertEqual(vm.drilledWorkbenchID, p)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(stopped.id)])
        XCTAssertEqual(launches.count, launchesBefore, "no claude --resume from a banner")
        XCTAssertFalse(vm.sessionState(stopped).live)
    }

    /// A subject that names no session of the workbench (deleted, or
    /// another workbench's) falls back to the live-else-latest one.
    func testTerminalDeepLinkWithAGoneSubjectFallsBack() async throws {
        let p = try await workbenchWithFolder()
        let other = try await workbenchWithFolder("other")
        let foreign = try await insertSession(.init(
            projectID: other, kind: .claude, title: "foreign", folderPath: acme,
            claudeSessionID: UUID().uuidString.lowercased()
        ))
        let vm = makeVM()
        let live = try await liveSession(p, "live")
        await vm.open(live)
        let gone = try await liveSession(p, "gone")
        try await pool.write { try TerminalSessionQueries.delete($0, id: gone.id) }
        let launchesBefore = launches.count

        await vm.revealTerminal(projectID: p, sessionID: gone.id)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(live.id)])
        await vm.revealTerminal(projectID: p, sessionID: foreign.id)
        XCTAssertEqual(vm.layout(projectID: p).visiblePanes, [.session(live.id)])
        XCTAssertEqual(launches.count, launchesBefore, "the fallback starts nothing")
    }

    /// Two overlapping reads, the older one finishing last: the newer list
    /// stays, and a session placed between the two starts is not pruned.
    func testAnOlderReadFinishingLastNeitherHidesTheNewListNorPrunesTheLayout() async throws {
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        let row = try await liveSession(p, "one")
        var gates: [CheckedContinuation<Void, Never>] = []
        var results: [[TerminalSession]] = [[], [row]]
        vm.readWorkbenchSessions = { _ in
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
        let p = try await workbenchWithFolder()
        let vm = makeVM()
        let row = try await liveSession(p, "one")
        var gates: [CheckedContinuation<Void, Never>] = []
        var results: [[TerminalSession]] = [[], [row]]
        vm.readWorkbenchSessions = { _ in
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

    // MARK: - Panel order (#143)

    /// Opening a session never moves it; a drag does, and the order outlives
    /// a relaunch; a session created later appears on top once.
    func testPanelOrderIsStableAndChangesOnlyByDrag() async throws {
        let p = try await workbenchWithFolder()
        let first = try await liveSession(p, "first")
        let second = try await liveSession(p, "second")
        let vm = makeVM()
        await vm.reload()
        vm.drill(into: p)
        await vm.loadSessions(projectID: p)
        XCTAssertEqual(vm.drilledSessions.map(\.id), [second.id, first.id])

        clock = clock.addingTimeInterval(60)
        await vm.showSession(id: first.id)
        XCTAssertEqual(vm.drilledSessions.map(\.id), [second.id, first.id], "opening does not raise it")

        vm.moveSessions(vm.drilledSessions, projectID: p, from: [1], to: 0)
        XCTAssertEqual(vm.drilledSessions.map(\.id), [first.id, second.id])

        let third = try await liveSession(p, "third")
        let relaunched = makeVM()
        await relaunched.reload()
        relaunched.drill(into: p)
        await relaunched.loadSessions(projectID: p)
        XCTAssertEqual(relaunched.drilledSessions.map(\.id), [third.id, first.id, second.id])
    }

    func testStandaloneAndProjectOrdersAreSavedApart() async throws {
        let p = try await workbenchWithFolder()
        let a = try await liveSession(p, "a")
        let b = try await liveSession(p, "b")
        let vm = makeVM()
        await vm.newStandalone(kind: .shell, folder: folder)
        await vm.newStandalone(kind: .shell, folder: folder)
        await vm.loadSessions(projectID: p)
        let shown = vm.orderedSessions(projectID: nil).map(\.id)
        XCTAssertEqual(shown.count, 2)

        vm.moveSessions(vm.orderedSessions(projectID: nil), projectID: nil, from: [0], to: 2)
        XCTAssertEqual(vm.orderedSessions(projectID: p).map(\.id), [b.id, a.id], "the project list is untouched")

        let relaunched = makeVM()
        await relaunched.reload()
        await relaunched.loadSessions(projectID: p)
        XCTAssertEqual(relaunched.orderedSessions(projectID: nil).map(\.id), shown.reversed())
        XCTAssertEqual(relaunched.orderedSessions(projectID: p).map(\.id), [b.id, a.id])
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
