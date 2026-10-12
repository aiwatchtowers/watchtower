import AppKit
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The sessions' places wired into the AppState-owned view model (board
/// #565): the page's git watch follows and unfollows the workbench, the
/// session state reads, the refs watcher and app activation drive the
/// re-reads. The CLI is a fake answering by argv; nothing is spawned.
@MainActor
final class SessionPlaceViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var project: Workbench!
    private var sessionID: Int64 = 0
    private let folder = "/tmp/acme"
    private let worktreeA = "/tmp/acme/.claude/worktrees/mobile-a"
    private let worktreeB = "/tmp/acme/.claude/worktrees/mobile-b"

    /// Answers `--folder` reads with a worktree envelope for that folder,
    /// every other status read with the main folder's (so the refs watcher
    /// arms).
    final class RoutingRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private var branchByFolder: [String: String] = [:]
        let workbenchID: Int64

        init(workbenchID: Int64) { self.workbenchID = workbenchID }

        /// The folders `--folder` reads asked for, in order.
        var folderReads: [String] {
            lock.withLock {
                recorded.compactMap { args in args.firstIndex(of: "--folder").map { args[$0 + 1] } }
            }
        }

        func setBranch(_ branch: String, folder: String) {
            lock.withLock { branchByFolder[folder] = branch }
        }

        func run(args: [String]) async throws -> Data {
            let folder: String? = lock.withLock {
                recorded.append(args)
                return args.firstIndex(of: "--folder").map { args[$0 + 1] }
            }
            guard let folder else {
                return Data(#"""
                    {"workbench_id":\#(workbenchID),"git_available":true,"git":true,"branch":"main","head":"a1b2c3d",
                     "dirty":false,"changes":0,"top_level":"/tmp/acme","git_dir":"/tmp/acme/.git",
                     "common_dir":"/tmp/acme/.git","status_ok":true,"status_error":""}
                    """#.utf8)
            }
            let branch = lock.withLock { branchByFolder[folder] ?? "feature/x" }
            let name = (folder as NSString).lastPathComponent
            return Data(#"""
                {"workbench_id":\#(workbenchID),"git":true,"branch":"\#(branch)","status_ok":true,
                 "folder_requested":"\#(folder)","folder_scope":"worktree","folder_root":"\#(folder)","worktree_name":"\#(name)"}
                """#.utf8)
        }
    }

    final class FakeWatcher: GitRefsWatching {
        let onChange: @MainActor (GitRefsChange) -> Void
        init(onChange: @escaping @MainActor (GitRefsChange) -> Void) { self.onChange = onChange }
        func stop() {}
    }

    override func setUp() async throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "SessionPlaceViewModelTests-\(UUID().uuidString)"))
        let folder = folder
        (project, sessionID) = try await pool.write { db -> (Workbench, Int64) in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            let row = try TerminalSessionQueries.create(db, .init(
                projectID: id, kind: .claude, title: "s", folderPath: folder, claudeSessionID: "uuid-1"
            ))
            return (try XCTUnwrap(WorkbenchQueries.fetch(db, id: id)), row.id)
        }
        try await storeCwd(worktreeA, at: "2026-10-12 10:00:00.000")
    }

    override func tearDown() async throws {
        TestDatabase.cleanup(path: path)
    }

    private func storeCwd(_ cwd: String, at stamp: String) async throws {
        let id = sessionID
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE terminal_sessions SET agent_cwd = ?, agent_cwd_at = ? WHERE id = ?",
                arguments: [cwd, stamp, id]
            )
        }
    }

    private func makeVM(
        _ runner: RoutingRunner, agentStates: SessionAgentStateCenter? = nil
    ) -> (WorkbenchesViewModel, NotificationCenter, () -> [FakeWatcher]) {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults,
                                      agentStates: agentStates)
        var watchers: [FakeWatcher] = []
        vm.makeGitWatcher = { _, _, onChange in
            let watcher = FakeWatcher(onChange: onChange)
            watchers.append(watcher)
            return watcher
        }
        vm.gitPollSleep = { _ in try? await Task.sleep(for: .seconds(3600)) }
        let center = NotificationCenter()
        vm.gitNotificationCenter = center
        return (vm, center, { watchers })
    }

    private func worktreeName(_ vm: WorkbenchesViewModel) -> String? {
        if case let .worktree(name, _, _) = vm.sessionPlaces.currentPlace(sessionID: sessionID) { return name }
        return nil
    }

    private func branch(_ vm: WorkbenchesViewModel) -> String? {
        if case let .worktree(_, _, status) = vm.sessionPlaces.currentPlace(sessionID: sessionID) { return status.branch }
        return nil
    }

    /// The page starting its git watch is what follows the workbench.
    func testTheViewModelPlacesASessionFromItsStoredCwd() async throws {
        let runner = RoutingRunner(workbenchID: project.id)
        let (vm, _, _) = makeVM(runner)

        await vm.startGitWatching(project: project)
        await waitUntil { self.worktreeName(vm) == "mobile-a" }
        vm.stopGitWatching(projectID: project.id)

        XCTAssertEqual(runner.folderReads, [worktreeA])
        let id = sessionID
        let stored = try await pool.read { try TerminalSessionQueries.fetch($0, id: id) }
        let session = try XCTUnwrap(stored)
        XCTAssertEqual(vm.sessionRows([session]).first?.place?.text, "⑂ mobile-a · feature/x")
    }

    /// Leaving the page unfollows: a later state change reads nothing.
    func testStoppingTheGitWatchUnfollows() async throws {
        let runner = RoutingRunner(workbenchID: project.id)
        let (vm, _, _) = makeVM(runner)
        await vm.startGitWatching(project: project)
        await waitUntil { self.worktreeName(vm) == "mobile-a" }
        vm.stopGitWatching(projectID: project.id)

        try await storeCwd(worktreeB, at: "2026-10-12 10:00:05.000")
        await vm.sessionPlaces.cwdsMayHaveChanged().value
        XCTAssertEqual(runner.folderReads, [worktreeA])
        XCTAssertEqual(worktreeName(vm), "mobile-a")
    }

    /// A state read showing a new cwd stamp re-reads the cwds; the same
    /// stamp again reads nothing.
    func testAStateReadWithANewCwdStampRereadsTheCwds() async throws {
        let runner = RoutingRunner(workbenchID: project.id)
        let stamp = LockedValue("2026-10-12 10:00:00.000")
        let projectID = project.id
        let id = sessionID
        let reader: SessionAgentStateCenter.Reader = { _ in
            [SessionAgentStateRow(id: id, projectID: projectID, title: "s", agentState: nil, agentStateAt: nil,
                                  workbenchName: "acme", agentCwdAt: stamp.value)]
        }
        let agentStates = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: TerminalCenter(), interval: .seconds(3600),
            notifier: RecordingSessionNotifier(), defaults: defaults, notificationCenter: NotificationCenter(),
            read: reader
        )
        let (vm, _, _) = makeVM(runner, agentStates: agentStates)
        await vm.startGitWatching(project: project)
        await waitUntil { self.worktreeName(vm) == "mobile-a" }

        try await storeCwd(worktreeB, at: "2026-10-12 10:00:05.000")
        stamp.value = "2026-10-12 10:00:05.000"
        await agentStates.poll()
        await waitUntil { self.worktreeName(vm) == "mobile-b" }
        await agentStates.poll()
        await settle()
        XCTAssertEqual(runner.folderReads, [worktreeA, worktreeB])
        vm.stopGitWatching(projectID: project.id)
    }

    /// A state change alone (no cwd stamp at all, so `stateRowsRead` asks
    /// for nothing) re-reads the cwds through `onChange`; a poll with no
    /// change and the same stamp reads nothing.
    func testAStateChangeWithoutANewCwdStampRereadsTheCwds() async throws {
        let runner = RoutingRunner(workbenchID: project.id)
        let rows = LockedValue<[SessionAgentStateRow]>([])
        let reader: SessionAgentStateCenter.Reader = { _ in rows.value }
        let agentStates = SessionAgentStateCenter(
            dbPool: pool, terminalCenter: TerminalCenter(), interval: .seconds(3600),
            notifier: RecordingSessionNotifier(), defaults: defaults, notificationCenter: NotificationCenter(),
            read: reader
        )
        let (vm, _, _) = makeVM(runner, agentStates: agentStates)
        await vm.startGitWatching(project: project)
        await waitUntil { self.worktreeName(vm) == "mobile-a" }

        try await storeCwd(worktreeB, at: "2026-10-12 10:00:05.000")
        await agentStates.poll()
        await settle()
        XCTAssertEqual(runner.folderReads, [worktreeA], "no change, no stamp: nothing is read")

        rows.value = [SessionAgentStateRow(id: sessionID, projectID: project.id, title: "s", agentState: nil,
                                           agentStateAt: nil, workbenchName: "acme", agentCwdAt: nil)]
        await agentStates.poll()
        await waitUntil { self.worktreeName(vm) == "mobile-b" }
        await agentStates.poll()
        await settle()
        XCTAssertEqual(runner.folderReads, [worktreeA, worktreeB])
        vm.stopGitWatching(projectID: project.id)
    }

    /// The refs watcher re-reads the worktree places only for a batch that
    /// may have moved another worktree; app activation always does.
    func testTheRefsWatcherAndActivationRefreshThePlaces() async throws {
        let runner = RoutingRunner(workbenchID: project.id)
        let (vm, center, watchers) = makeVM(runner)
        await vm.startGitWatching(project: project)
        await waitUntil { self.worktreeName(vm) == "mobile-a" }
        let watcher = try XCTUnwrap(watchers().first)

        watcher.onChange(GitRefsChange(mayMoveWorktrees: false))
        await settle()
        XCTAssertEqual(runner.folderReads, [worktreeA], "only the folder's own HEAD/index moved")

        runner.setBranch("feature/y", folder: worktreeA)
        watcher.onChange(GitRefsChange(mayMoveWorktrees: true))
        await waitUntil { self.branch(vm) == "feature/y" }

        runner.setBranch("feature/z", folder: worktreeA)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await waitUntil { self.branch(vm) == "feature/z" }
        XCTAssertEqual(runner.folderReads, [worktreeA, worktreeA, worktreeA])
        vm.stopGitWatching(projectID: project.id)
    }

    // MARK: - Helpers

    final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met in \(timeout)s")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets queued main-actor tasks run.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }
}
