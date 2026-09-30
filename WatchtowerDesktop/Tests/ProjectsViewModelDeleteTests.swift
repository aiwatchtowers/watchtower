import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// Review Focus #5 (Desktop side): deleting a project while Claude Code is
/// connected closes its terminal first, and a failed delete keeps it listed.
@MainActor
final class ProjectsViewModelDeleteTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "ProjectsViewModelDeleteTests-\(UUID().uuidString)"))
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    /// Stands in for `watchtower project delete N`: records the call and, unless
    /// told to fail, deletes the row the way the CLI's transaction would.
    private final class DeletingCLIRunner: CLIRunnerProtocol, @unchecked Sendable {
        let pool: DatabasePool
        var fail = false
        var removalError = ""
        private(set) var calls: [[String]] = []
        init(pool: DatabasePool) { self.pool = pool }

        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if fail { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked") }
            guard args.count == 4, args[0] == "project", args[1] == "delete", let id = Int64(args[2]) else {
                return Data()
            }
            try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id]) }
            let envelope: [String: Any] = [
                "id": id, "deleted": true, "removal_ok": removalError.isEmpty, "removal_error": removalError
            ]
            return try JSONSerialization.data(withJSONObject: envelope)
        }
    }

    private func makeVM(_ runner: DeletingCLIRunner) -> ProjectsViewModel {
        ProjectsViewModel(dbPool: pool, cli: ProjectCLI(runner: runner), defaults: defaults)
    }

    func testDeleteClosesTheTerminalBeforeTheCLIRunsThenDropsTheProject() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = DeletingCLIRunner(pool: pool)
        let vm = makeVM(runner)
        await vm.reload()
        vm.selectedProjectID = id
        var closedBeforeCLI: [Int64] = []
        vm.closeTerminal = { closed in
            if runner.calls.isEmpty { closedBeforeCLI.append(closed) }
        }

        let ok = await vm.deleteProject(id)

        XCTAssertTrue(ok)
        XCTAssertEqual(closedBeforeCLI, [id], "the terminal closes before `project delete` runs")
        XCTAssertEqual(runner.calls, [["project", "delete", String(id), "--json"]])
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.selectedProjectID)
        XCTAssertNil(vm.deleteError)
        XCTAssertNil(vm.errorMessage)
        XCTAssertNil(vm.deletingProjectID)
    }

    /// The rows are gone but the folder cleanup failed: the project still
    /// leaves the list, and a non-blocking warning names the removal error.
    func testFolderCleanupFailureDeletesTheProjectAndWarns() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = DeletingCLIRunner(pool: pool)
        runner.removalError = "permission denied: .claude/skills"
        let vm = makeVM(runner)
        await vm.reload()

        let ok = await vm.deleteProject(id)

        XCTAssertTrue(ok)
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.deleteError, "a cleanup failure is a warning, not a failed delete")
        XCTAssertTrue(vm.errorMessage?.contains("permission denied: .claude/skills") ?? false)
    }

    func testCLIFailureKeepsTheProjectAndShowsTheError() async throws {
        let id = try await pool.write { try TestDatabase.insertProject($0) }
        let runner = DeletingCLIRunner(pool: pool)
        runner.fail = true
        let vm = makeVM(runner)
        await vm.reload()

        let ok = await vm.deleteProject(id)

        XCTAssertFalse(ok)
        XCTAssertEqual(vm.summaries.map(\.id), [id])
        XCTAssertNotNil(vm.deleteError)
        XCTAssertTrue(vm.deleteError?.contains("database is locked") ?? false)
        XCTAssertNil(vm.deletingProjectID)
    }

    func testASecondDeleteWhileOneRunsIsRefused() async throws {
        let (a, b) = try await pool.write { d in
            (try TestDatabase.insertProject(d, name: "a", folder: "/tmp/a"),
             try TestDatabase.insertProject(d, name: "b", folder: "/tmp/b"))
        }
        let runner = DeletingCLIRunner(pool: pool)
        let vm = makeVM(runner)
        await vm.reload()
        let gate = AsyncStream<Void>.makeStream()
        // Holds the first delete inside closeTerminal; finishing the stream
        // releases it and every later call (reload's vanished-close) at once.
        vm.closeTerminal = { _ in for await _ in gate.stream { break } }

        let first = Task { await vm.deleteProject(a) }
        while vm.deletingProjectID == nil { await Task.yield() }
        let second = await vm.deleteProject(b)
        gate.continuation.yield()
        gate.continuation.finish()
        _ = await first.value

        XCTAssertFalse(second)
        XCTAssertEqual(runner.calls, [["project", "delete", String(a), "--json"]])
    }

    func testReloadClosesTheTerminalOfAProjectDeletedFromOutside() async throws {
        let (a, b) = try await pool.write { d in
            (try TestDatabase.insertProject(d, name: "a", folder: "/tmp/a"),
             try TestDatabase.insertProject(d, name: "b", folder: "/tmp/b"))
        }
        let vm = makeVM(DeletingCLIRunner(pool: pool))
        await vm.reload()
        var closed: [Int64] = []
        vm.closeTerminal = { closed.append($0) }

        // `watchtower project delete` from a terminal, not through the VM.
        try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [a]) }
        await vm.reload()

        XCTAssertEqual(closed, [a])
        XCTAssertEqual(vm.summaries.map(\.id), [b])
    }

    func testVanishedListsIDsThatDisappeared() {
        XCTAssertEqual(ProjectsViewModel.vanished(previous: [1, 2, 3], current: [3, 1]), [2])
        XCTAssertEqual(ProjectsViewModel.vanished(previous: [], current: [1]), [])
    }

    /// AppState wiring: initProjects hands the VM `TerminalCenter.closeAll`
    /// over the project's sessions, so a delete ends every terminal of that
    /// project — and only those.
    func testInitProjectsWiresDeleteToTheTerminalCenter() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertProject($0, name: "acme", folder: folder.path) }
        let other = try await pool.write { try TestDatabase.insertProject($0, name: "other", folder: folder.path + "/x") }
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

        let appState = AppState()
        // pid 0: close() never signals a real process group.
        var processes: [FakeTerminalSession] = []
        appState.terminalCenter.makeProcess = {
            let process = FakeTerminalSession(pid: 0)
            processes.append(process)
            return process
        }
        appState.initProjects(dbPool: pool, cliRunner: DeletingCLIRunner(pool: pool), notifier: RecordingProjectNotifier())
        let vm = try XCTUnwrap(appState.projectsViewModel)
        await vm.reload()
        for s in [a, b, kept] { appState.terminalCenter.start(s, fresh: true) }
        XCTAssertEqual(appState.terminalCenter.liveIDs, [a.id, b.id, kept.id])

        let ok = await vm.deleteProject(id)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.terminalCenter.liveIDs, [kept.id])
        XCTAssertEqual(processes.map(\.detached), [true, true, false])
    }
}
