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
        private(set) var calls: [[String]] = []
        init(pool: DatabasePool) { self.pool = pool }

        func run(args: [String]) async throws -> Data {
            calls.append(args)
            if fail { throw CLIRunnerError.nonZeroExit(code: 1, stderr: "database is locked") }
            if args.count == 3, args[0] == "project", args[1] == "delete", let id = Int64(args[2]) {
                try await pool.write { try $0.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [id]) }
            }
            return Data()
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
        XCTAssertEqual(runner.calls, [["project", "delete", String(id)]])
        XCTAssertTrue(vm.summaries.isEmpty)
        XCTAssertNil(vm.selectedProjectID)
        XCTAssertNil(vm.deleteError)
        XCTAssertNil(vm.deletingProjectID)
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
        XCTAssertEqual(runner.calls, [["project", "delete", String(a)]])
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

    /// AppState wiring: initProjects hands the VM ProjectTerminalCenter.close,
    /// so a delete really ends the project's terminal session.
    func testInitProjectsWiresDeleteToTheTerminalCenter() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try await pool.write { try TestDatabase.insertProject($0, name: "acme", folder: folder.path) }
        let fetched = try await pool.read { try ProjectQueries.fetch($0, id: id) }
        let project = try XCTUnwrap(fetched)

        let appState = AppState()
        // pid 0: close() never signals a real process group.
        let session = FakeTerminalSession(pid: 0)
        appState.projectTerminalCenter.makeSession = { session }
        appState.initProjects(dbPool: pool, cliRunner: DeletingCLIRunner(pool: pool), notifier: RecordingProjectNotifier())
        let vm = try XCTUnwrap(appState.projectsViewModel)
        await vm.reload()
        appState.projectTerminalCenter.start(project: project)
        XCTAssertNotNil(appState.projectTerminalCenter.states[id])

        let ok = await vm.deleteProject(id)

        XCTAssertTrue(ok)
        XCTAssertNil(appState.projectTerminalCenter.states[id])
        XCTAssertTrue(session.detached)
    }
}
