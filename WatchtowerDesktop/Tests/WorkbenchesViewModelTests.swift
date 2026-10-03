import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class WorkbenchesViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(_ runner: any CLIRunnerProtocol = FakeCLIRunner()) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    private func createdJSON(_ id: Int64) -> Data {
        Data(#"{"id":\#(id),"folder":"/tmp/acme","name":"acme"}"#.utf8)
    }

    func testReloadBuildsSummariesAndTheBadgeCountsUnreadAgentComments() async throws {
        let p = try await pool.write { d -> Int64 in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t, readAt: "seen")
            return p
        }
        let vm = makeVM()
        await vm.reload()
        XCTAssertEqual(vm.summaries.map(\.id), [p])
        XCTAssertEqual(vm.badgeCount, 1, "one unread agent comment; a read one does not count")
    }

    /// Spec 2026-10-03 Part 8: the badge is open asks plus unread agent
    /// target comments, summed over the workbenches.
    func testTheBadgeCountsOpenAsksPlusUnreadAgentComments() async throws {
        let (p, other) = try await pool.write { d -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p)
            _ = try TestDatabase.insertWorkbenchComment(d, projectID: p, targetID: t)
            _ = try TestDatabase.insertOwnerAsk(d, projectID: p)
            _ = try TestDatabase.insertOwnerAsk(d, projectID: p, title: "Check the build")
            for status in ["answered", "delivered", "withdrawn"] {
                _ = try TestDatabase.insertOwnerAsk(d, projectID: p, status: status, answer: status == "withdrawn" ? "" : "{}")
            }
            let other = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            _ = try TestDatabase.insertOwnerAsk(d, projectID: other)
            return (p, other)
        }
        let vm = makeVM()
        await vm.reload()
        let summaries = Dictionary(uniqueKeysWithValues: vm.summaries.map { ($0.id, $0) })
        XCTAssertEqual(summaries[p].map(vm.badgeCount(for:)), 3, "two open asks and one unread comment; closed asks never count")
        XCTAssertEqual(summaries[other].map(vm.badgeCount(for:)), 1)
        XCTAssertEqual(vm.badgeCount, 4)
    }

    /// An ask whose session row was deleted (`session_id` set to NULL by the
    /// foreign key) is still open: it still counts.
    func testAnOpenAskWhoseSessionWasDeletedStillCounts() async throws {
        try await pool.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let s = try TerminalSessionQueries.create(d, .init(projectID: p, kind: .shell, title: "s", folderPath: "/tmp/acme")).id
            try TestDatabase.insertOwnerAsk(d, projectID: p, sessionID: s)
            try TerminalSessionQueries.delete(d, id: s)
            let orphaned = try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM owner_asks WHERE session_id IS NULL")
            XCTAssertEqual(orphaned, 1, "the delete nulls the ask's session")
        }
        let vm = makeVM()
        await vm.reload()
        XCTAssertEqual(vm.badgeCount, 1)
    }

    /// The notification center's poll reloads the list, so an ask the agent
    /// files from another process lights the badge without a navigation, and
    /// the owner's answer clears it.
    func testRefreshOnPollPicksUpAnAskAndItsAnswer() async throws {
        let p = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let vm = makeVM()
        await vm.reload()
        XCTAssertEqual(vm.badgeCount, 0)

        let ask = try await pool.write { try TestDatabase.insertOwnerAsk($0, projectID: p) }
        await vm.refreshOnPoll()
        XCTAssertEqual(vm.badgeCount, 1)

        try await pool.write { try OwnerAskQueries.answer($0, askID: ask, projectID: p, with: OwnerAskAnswer()) }
        await vm.refreshOnPoll()
        XCTAssertEqual(vm.badgeCount, 0)
    }

    func testCreateRunsCreateThenInstallSelectsTheProjectAndAnnouncesIt() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .success(Data("installed".utf8)),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [Int64] = []
        vm.onWorkbenchCreated = { project, installed in if installed { announced.append(project.id) } }

        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)

        XCTAssertEqual(runner.invocations.map { Array($0.prefix(2)) }, [
            ["workbench", "create"], ["integrate", "claude-code"], ["integrate", "status"]
        ])
        XCTAssertEqual(vm.selectedWorkbenchID, id)
        guard case .session = vm.layout.primary else { return XCTFail("the setup session goes on screen") }
        XCTAssertEqual(announced, [id])
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
        XCTAssertFalse(vm.isCreating)
    }

    func testInstallFailureKeepsTheProjectAndPointsAtRepair() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let vm = makeVM(runner)
        var announced: [(Int64, Bool)] = []
        vm.onWorkbenchCreated = { announced.append(($0.id, $1)) }
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertEqual(vm.selectedWorkbenchID, id)
        XCTAssertTrue(vm.installErrors[id]?.contains("Repair") == true)
        XCTAssertTrue(vm.installErrors[id]?.contains("claude not found") == true, "the install error is shown")
        XCTAssertNil(vm.errorMessage, "the note belongs to its project, not the list-wide line")
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, true)
        XCTAssertEqual(announced.map(\.0), [id], "the baseline is still seeded")
        XCTAssertEqual(announced.map(\.1), [false], "no first-run terminal after a failed install")
    }

    func testCreateFailureShowsTheCLIErrorAndAnnouncesNothing() async {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "folder is already bound to a project"))
        let vm = makeVM(runner)
        var announced = false
        vm.onWorkbenchCreated = { _, _ in announced = true }
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        XCTAssertTrue(vm.errorMessage?.contains("already bound") == true)
        XCTAssertNil(vm.selectedWorkbenchID)
        XCTAssertFalse(announced)
    }

    func testRepairRunsIntegrateAndRefreshesTheStatus() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.repairInstall(projectID: id)
        XCTAssertEqual(runner.invocations, [
            ["integrate", "claude-code", "--workbench", String(id)],
            ["integrate", "status", "--workbench", String(id), "--json"]
        ])
        XCTAssertEqual(vm.installStatus[id]?.needsRepair, false)
    }

    /// Switching projects cancels the page's `.task(id:)` status read while
    /// the CLI still runs: the cancellation is not an error, and the last
    /// known status stays.
    func testCancelledStatusReadKeepsTheStatusAndReportsNothing() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        await vm.refreshInstallStatus(projectID: 1)
        XCTAssertNotNil(vm.installStatus[1])

        runner.blockUntilCancelled = true
        let read = Task { await vm.refreshInstallStatus(projectID: 1) }
        read.cancel()
        await read.value

        XCTAssertEqual(vm.installStatus[1]?.needsRepair, false, "the previous status is kept")
        XCTAssertNil(vm.installErrors[1])
        XCTAssertNil(vm.errorMessage)
    }

    /// House rule: started → navigated away → result arrives. The process
    /// runner terminates the child on cancel, so the read can fail with a
    /// non-zero exit rather than CancellationError — still silent.
    func testStatusReadThatFailsAfterTheOwnerSwitchedAwayIsSilent() async throws {
        let held = HeldCLIRunner(error: CLIRunnerError.nonZeroExit(code: 15, stderr: ""))
        let vm = makeVM(held)
        vm.selectedWorkbenchID = 1
        let read = Task { await vm.refreshInstallStatus(projectID: 1) }
        await awaitStarted(held)

        vm.selectedWorkbenchID = 2
        read.cancel()
        held.release()
        await read.value

        XCTAssertNil(vm.installErrors[1])
        XCTAssertNil(vm.installErrors[2])
        XCTAssertNil(vm.errorMessage, "nothing lands in the shared list-wide error line")
    }

    func testStatusReadFailureIsScopedToItsProjectAndClearedByTheNextRead() async throws {
        let runner = ScriptedCLIRunner(results: [
            .success(Data(#"{"skill":"missing","hook":false,"mcp":true}"#.utf8)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.refreshInstallStatus(projectID: 1)
        await vm.refreshInstallStatus(projectID: 1)
        XCTAssertTrue(vm.installErrors[1]?.contains("boom") == true)
        XCTAssertEqual(vm.installStatus[1]?.needsRepair, true, "the last known status (and its Repair) stays")
        XCTAssertNil(vm.installErrors[2])
        XCTAssertNil(vm.errorMessage)

        await vm.refreshInstallStatus(projectID: 1)
        XCTAssertNil(vm.installErrors[1])
        XCTAssertEqual(vm.installStatus[1]?.needsRepair, false)
    }

    /// Selecting the new project starts the page's own status read, racing
    /// `createWorkbench`'s: a later read that still needs repair keeps the note.
    func testCreateTimeInstallNoteSurvivesTheNextStatusRead() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let missing = Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8)
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(missing),
            .success(missing),
            .success(Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil)
        await vm.refreshInstallStatus(projectID: id)
        XCTAssertTrue(vm.installErrors[id]?.contains("claude not found") == true, "the note still explains Repair")

        await vm.refreshInstallStatus(projectID: id)
        XCTAssertNil(vm.installErrors[id], "a healthy install clears it")
    }

    /// A successful Repair of one project leaves the list-wide line (another
    /// operation's failure) alone.
    func testRepairSuccessLeavesTheListWideErrorAlone() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"skill":"unchanged","hook":true,"mcp":true}"#.utf8))
        let vm = makeVM(runner)
        vm.errorMessage = "Could not load workbenches"
        await vm.repairInstall(projectID: 1)
        XCTAssertEqual(vm.errorMessage, "Could not load workbenches")
    }

    func testRepairFailureStaysShownAfterTheStatusRefresh() async throws {
        let runner = ScriptedCLIRunner(results: [
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let vm = makeVM(runner)
        await vm.repairInstall(projectID: 3)
        XCTAssertTrue(vm.installErrors[3]?.contains("Repair failed") == true)
        XCTAssertEqual(vm.installStatus[3]?.needsRepair, true)
    }

    func testRevealSelectsTheProjectAndPane() {
        let vm = makeVM()
        vm.selectedWorkbenchID = 4
        vm.layout.show(.files)
        XCTAssertEqual(vm.layout.visiblePanes, [.files], "the reveal must move the pane")
        vm.reveal(WorkbenchRoute(projectID: 4, pane: .board, subjectID: 9))
        XCTAssertEqual(vm.selectedWorkbenchID, 4)
        XCTAssertEqual(vm.layout.visiblePanes, [.board])
    }

    /// House rule: an async operation started from a screen survives leaving
    /// it. The VM lives on AppState, so the create keeps running while the
    /// owner is on another tab and the result is there when they return.
    func testCreateSurvivesNavigatingAwayAndSelectsTheProjectOnReturn() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let held = HeldCLIRunner(stdout: createdJSON(id))
        let appState = AppState.isolated()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: held, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        appState.selectedDestination = .workbench

        let run = Task { await vm.createWorkbench(folder: URL(fileURLWithPath: "/tmp/acme"), name: nil) }
        await awaitStarted(held)
        XCTAssertTrue(vm.isCreating)

        appState.selectedDestination = .inbox
        held.release()
        await run.value

        appState.selectedDestination = .workbench
        XCTAssertTrue(appState.workbenchesViewModel === vm, "the same AppState-owned VM, not a fresh one")
        XCTAssertEqual(vm.selectedWorkbenchID, id)
        XCTAssertFalse(vm.isCreating)
    }

    /// AppState wiring: after a failed install the first-run terminal must
    /// not start (setup would run without the skill/hook/MCP server).
    func testFailedInstallStartsNoFirstRunTerminal() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .failure(CLIRunnerError.nonZeroExit(code: 1, stderr: "claude not found")),
            .success(Data(#"{"skill":"missing","hook":false,"mcp":false}"#.utf8))
        ])
        let appState = AppState.isolated()
        appState.terminalCenter.makeProcess = { FakeTerminalSession() }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let vm = try XCTUnwrap(appState.workbenchesViewModel)

        await vm.createWorkbench(folder: folder, name: nil)

        XCTAssertEqual(vm.selectedWorkbenchID, id)
        XCTAssertTrue(appState.terminalCenter.states.isEmpty, "no terminal after a failed install")
        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertTrue(rows.isEmpty, "no setup session row after a failed install")
    }

    /// A double click on Start Claude Code / Open terminal: two overlapping
    /// calls create one row and start one process.
    func testConcurrentOpenMostRecentSessionCreatesOneRow() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        var processes: [FakeTerminalSession] = []
        let center = TerminalCenter {
            let process = FakeTerminalSession(pid: 0)
            processes.append(process)
            return process
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        await vm.reload()
        let project = try XCTUnwrap(vm.summaries.first { $0.id == id }?.project)

        async let first: Void = vm.openMostRecentSession(project: project)
        async let second: Void = vm.openMostRecentSession(project: project)
        _ = await (first, second)

        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(processes.flatMap(\.launches).count, 1)

        await vm.openMostRecentSession(project: project)
        let after = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertEqual(after.map(\.id), rows.map(\.id), "the next open reuses the row")
        XCTAssertEqual(processes.flatMap(\.launches).count, 1, "a running session is not relaunched")
        XCTAssertEqual(center.focusOrder, [rows[0].id])
    }

    /// A failed list load says nothing about the project's sessions, so Open
    /// terminal must not start a duplicate "New session" row from it.
    func testOpenMostRecentSessionStartsNothingWhenTheLoadFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        var processes: [FakeTerminalSession] = []
        let center = TerminalCenter {
            let process = FakeTerminalSession(pid: 0)
            processes.append(process)
            return process
        }
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults,
                                      terminalCenter: center)
        await vm.reload()
        let project = try XCTUnwrap(vm.summaries.first { $0.id == id }?.project)

        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions RENAME TO terminal_sessions_hidden") }
        await vm.openMostRecentSession(project: project)
        try await pool.write { try $0.execute(sql: "ALTER TABLE terminal_sessions_hidden RENAME TO terminal_sessions") }

        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(processes.flatMap(\.launches).isEmpty)
        XCTAssertNotNil(vm.sessionErrors[id])
    }

    /// A created and installed workbench gets one "Workbench setup" claude row,
    /// started fresh with its own session id and the first-run prompt.
    func testInstalledProjectStartsTheSetupSessionFresh() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wt-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let runner = ScriptedCLIRunner(results: [
            .success(createdJSON(id)),
            .success(Data()),
            .success(Data(#"{"skill":"installed","hook":true,"mcp":true}"#.utf8))
        ])
        let appState = AppState.isolated()
        let process = FakeTerminalSession(pid: 0)
        appState.terminalCenter.makeProcess = { process }
        appState.terminalCenter.shell = { "/bin/zsh" }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: runner, notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let vm = try XCTUnwrap(appState.workbenchesViewModel)

        await vm.createWorkbench(folder: folder, name: nil)

        let rows = try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: id) }
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.kind, .claude)
        XCTAssertEqual(row.title, TerminalSessionNaming.setupTitle)
        let uuid = try XCTUnwrap(row.claudeSessionID)
        XCTAssertTrue(TerminalLaunch.isValidSessionID(uuid))
        XCTAssertEqual(appState.terminalCenter.states[row.id], .running)
        XCTAssertEqual(appState.terminalCenter.focusOrder, [row.id])
        XCTAssertEqual(process.launches.last?.args.last,
                       "exec env -u WATCHTOWER_FIRST_PROMPT claude --session-id \(uuid) \"$WATCHTOWER_FIRST_PROMPT\"")
        XCTAssertEqual(process.launches.last?.environment.last, "WATCHTOWER_FIRST_PROMPT=\(TerminalLaunch.firstRunPrompt(.current))")
        XCTAssertEqual(vm.terminalSessions[id]?.map(\.id), [row.id])
    }

    func testNavigateToProjectSetsThePendingRouteAndTheTab() {
        let appState = AppState.isolated()
        appState.navigateToWorkbench(WorkbenchRoute(projectID: 2, pane: .board))
        XCTAssertEqual(appState.selectedDestination, .workbench)
        XCTAssertEqual(appState.pendingWorkbenchRoute, WorkbenchRoute(projectID: 2, pane: .board))
    }

}

/// Returns one scripted result per call, in order (the last one repeats).
final class ScriptedCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<Data, Error>]
    private var recorded: [[String]] = []

    init(results: [Result<Data, Error>]) {
        self.results = results
    }

    var invocations: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func run(args: [String]) async throws -> Data {
        lock.lock()
        recorded.append(args)
        let next = results.count > 1 ? results.removeFirst() : results[0]
        lock.unlock()
        return try next.get()
    }
}
