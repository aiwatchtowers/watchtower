import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Review Focus #5 (Desktop side): deleting a project while Claude Code is
/// connected closes its terminal first, and a failed delete keeps it listed.
@MainActor
final class WorkbenchesViewModelDeleteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelDeleteTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// Stands in for `watchtower workbench delete N`: records the call and, unless
    /// told to fail, deletes the row the way the CLI's transaction would.
    private final class DeletingCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
        let pool: DatabasePool
        var fail = false
        var removalError = ""
        var filesError = ""
        private(set) var calls: [[String]] = []
        init(pool: DatabasePool) { self.pool = pool }

        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if fail { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked") }
            guard args.count == 4, args[0] == "workbench", args[1] == "delete", let id = Int64(args[2]) else {
                return Data()
            }
            try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id]) }
            let envelope: [String: Any] = [
                "id": id, "deleted": true, "removal_ok": removalError.isEmpty, "removal_error": removalError,
                "files_ok": filesError.isEmpty, "files_error": filesError
            ]
            return try JSONSerialization.data(withJSONObject: envelope)
        }
    }

    private func makeVM(_ runner: DeletingCLIRunner) -> WorkbenchesViewModel {
        WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
    }

    func testDeleteClosesTheTerminalBeforeTheCLIRunsThenDropsTheProject() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = DeletingCLIRunner(pool: pool)
        let vm = makeVM(runner)
        await vm.reload()
        vm.selectedWorkbenchID = id
        var closedBeforeCLI: [Int64] = []
        vm.closeTerminal = { closed in
            if runner.calls.isEmpty { closedBeforeCLI.append(closed) }
        }
        var removedAfterCLI: [Int64] = []
        vm.onWorkbenchRemoved = { removed in
            if !runner.calls.isEmpty { removedAfterCLI.append(removed) }
        }

        let ok = await vm.deleteWorkbench(id)

        XCTAssertTrue(ok)
        XCTAssertEqual(closedBeforeCLI, [id], "the terminal closes before `project delete` runs")
        XCTAssertEqual(removedAfterCLI.first, id, "the code questions stop once their rows are gone")
        XCTAssertEqual(runner.calls, [["workbench", "delete", String(id), "--json"]])
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.selectedWorkbenchID)
        XCTAssertNil(vm.deleteError)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.deletingWorkbenchID)
    }

    /// The rows are gone but the folder cleanup failed: the project still
    /// leaves the list, and a non-blocking warning names the removal error.
    func testFolderCleanupFailureDeletesTheProjectAndWarns() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = DeletingCLIRunner(pool: pool)
        runner.removalError = "permission denied: .claude/skills"
        let vm = makeVM(runner)
        await vm.reload()

        let ok = await vm.deleteWorkbench(id)

        XCTAssertTrue(ok)
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.deleteError, "a cleanup failure is a warning, not a failed delete")
        XCTAssertTrue(vm.errorMessage?.contains("permission denied: .claude/skills") ?? false)
    }

    /// The stored image copies could not all be removed: the delete stands
    /// and the owner is told (PROJ-02 — never a silent leftover).
    func testImageCleanupFailureDeletesTheProjectAndWarns() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = DeletingCLIRunner(pool: pool)
        runner.filesError = "permission denied: project_files/1"
        let vm = makeVM(runner)
        await vm.reload()

        let ok = await vm.deleteWorkbench(id)

        XCTAssertTrue(ok)
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.deleteError)
        XCTAssertTrue(vm.errorMessage?.contains("stored images failed: permission denied: project_files/1") ?? false)
    }

    func testCLIFailureKeepsTheProjectAndShowsTheError() async throws {
        let id = try await pool.write { try TestDatabase.insertWorkbench($0) }
        let runner = DeletingCLIRunner(pool: pool)
        runner.fail = true
        let vm = makeVM(runner)
        await vm.reload()
        var removed: [Int64] = []
        vm.onWorkbenchRemoved = { removed.append($0) }

        let ok = await vm.deleteWorkbench(id)

        XCTAssertFalse(ok)
        XCTAssertEqual(removed, [], "a failed delete leaves the code questions alone")
        XCTAssertEqual(vm.summaries.map(\.id), [id])
        XCTAssertNotNil(vm.deleteError)
        XCTAssertTrue(vm.deleteError?.contains("database is locked") ?? false)
        XCTAssertNil(vm.deletingWorkbenchID)
    }

    func testASecondDeleteWhileOneRunsIsRefused() async throws {
        let (a, b) = try await pool.write { d in
            (try TestDatabase.insertWorkbench(d, name: "a", folder: "/tmp/a"),
             try TestDatabase.insertWorkbench(d, name: "b", folder: "/tmp/b"))
        }
        let runner = DeletingCLIRunner(pool: pool)
        let vm = makeVM(runner)
        await vm.reload()
        let gate = AsyncStream<Void>.makeStream()
        // Holds the first delete inside closeTerminal; finishing the stream
        // releases it and every later call (reload's vanished-close) at once.
        vm.closeTerminal = { _ in for await _ in gate.stream { break } }

        let first = Task { await vm.deleteWorkbench(a) }
        while vm.deletingWorkbenchID == nil { await Task.yield() }
        let second = await vm.deleteWorkbench(b)
        gate.continuation.yield()
        gate.continuation.finish()
        _ = await first.value

        XCTAssertFalse(second)
        XCTAssertEqual(runner.calls, [["workbench", "delete", String(a), "--json"]])
    }

    func testReloadClosesTheTerminalOfAProjectDeletedFromOutside() async throws {
        let (a, b) = try await pool.write { d in
            (try TestDatabase.insertWorkbench(d, name: "a", folder: "/tmp/a"),
             try TestDatabase.insertWorkbench(d, name: "b", folder: "/tmp/b"))
        }
        let vm = makeVM(DeletingCLIRunner(pool: pool))
        await vm.reload()
        var closed: [Int64] = []
        vm.closeTerminal = { closed.append($0) }
        var removed: [Int64] = []
        vm.onWorkbenchRemoved = { removed.append($0) }

        // `watchtower workbench delete` from a terminal, not through the VM.
        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [a]) }
        await vm.reload()

        XCTAssertEqual(closed, [a])
        XCTAssertEqual(removed, [a], "the code questions forget a workbench deleted elsewhere, not the one left")
        XCTAssertEqual(vm.summaries.map(\.id), [b])
    }

    func testVanishedListsIDsThatDisappeared() {
        XCTAssertEqual(WorkbenchesViewModel.vanished(previous: [1, 2, 3], current: [3, 1]), [2])
        XCTAssertEqual(WorkbenchesViewModel.vanished(previous: [], current: [1]), [])
    }

    /// AppState wiring: initWorkbenches hands the VM `TerminalCenter.closeAll`
    /// over the project's sessions, so a delete ends every terminal of that
    /// project — and only those.
    func testInitProjectsWiresDeleteToTheTerminalCenter() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertWorkbench($0, name: "acme", folder: folder.path) }
        let other = try await pool.write { try TestDatabase.insertWorkbench($0, name: "other", folder: folder.path + "/x") }
        func session(_ projectID: Int64) async throws -> TerminalSession {
            try await pool.write { d in
                try TerminalSessionQueries.create(d, .init(
                    projectID: projectID, kind: .claude, title: "s",
                    folderPath: folder.path, claudeSessionID: UUID().uuidString.lowercased()
                ))
            }
        }
        let a = try await session(id)
        let b = try await session(id)
        let kept = try await session(other)

        let appState = AppState.isolated()
        // pid 0: close() never signals a real process group.
        var processes: [FakeTerminalSession] = []
        appState.terminalCenter.makeProcess = {
            let process = FakeTerminalSession(pid: 0)
            processes.append(process)
            return process
        }
        appState.initWorkbenches(
            dbPool: pool, cliRunner: DeletingCLIRunner(pool: pool), notifier: RecordingWorkbenchNotifier(),
            sessionNotifier: RecordingSessionNotifier()
        )
        let vm = try XCTUnwrap(appState.workbenchesViewModel)
        XCTAssertEqual(appState.codeUsagesCenter.workspace, pool.path, "the inspector state is this workspace's")
        await vm.reload()
        for s in [a, b, kept] { appState.terminalCenter.start(s, fresh: true) }
        XCTAssertEqual(appState.terminalCenter.liveIDs, [a.id, b.id, kept.id])

        let ok = await vm.deleteWorkbench(id)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.terminalCenter.liveIDs, [kept.id])
        XCTAssertEqual(processes.map(\.detached), [true, true, false])
    }
}
