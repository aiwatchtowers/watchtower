import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Where a new workbench agent session starts (spec
/// 2026-10-14-session-worktrees-design.md §4, §7): the main folder, or its
/// own worktree made through `workbench worktree create`.
@MainActor
final class WorkbenchesViewModelPlacementTests: XCTestCase {
    /// `workbench git status` answers a git repository; `worktree create`
    /// answers `createReply` (by default a worktree at `worktree`).
    final class PlacementRunner: CLIRunnerProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        private let workbenchID: Int64
        private let worktree: String
        private var reply: String?

        init(workbenchID: Int64, worktree: String) {
            self.workbenchID = workbenchID
            self.worktree = worktree
        }

        var calls: [[String]] { lock.withLock { recorded } }

        /// The `--name` of every `worktree create`, in order.
        var createdNames: [String] {
            calls.filter { $0.starts(with: ["workbench", "worktree", "create"]) }
                .compactMap { args in args.firstIndex(of: "--name").map { args[$0 + 1] } }
        }

        func setCreateReply(_ json: String) { lock.withLock { reply = json } }

        /// The `worktree ensure` answer; nil = a created worktree at `worktree`.
        func setEnsureReply(_ json: String) { lock.withLock { ensureReply = json } }
        private var ensureReply: String?
        /// Runs when `worktree ensure` is called (the CLI re-adds the directory).
        var onEnsure: (@Sendable () -> Void)?

        var ensureCalls: [[String]] { calls.filter { $0.starts(with: ["workbench", "worktree", "ensure"]) } }

        func run(args: [String]) async throws -> Data {
            let custom: String? = lock.withLock {
                recorded.append(args)
                return reply
            }
            if args.starts(with: ["workbench", "worktree", "ensure"]) {
                let custom = lock.withLock { ensureReply }
                onEnsure?()
                return Data((custom ?? #"""
                    {"workbench_id":\#(workbenchID),"created":true,"path":"\#(worktree)","cwd":"\#(worktree)",
                     "branch":"wt/x","base":"a1b2c3d4e5f6","base_branch":"main","base_dirty":false,
                     "included":[],"include_warnings":[]}
                    """#).utf8)
            }
            if args.starts(with: ["workbench", "worktree", "create"]) {
                let name = args.firstIndex(of: "--name").map { args[$0 + 1] } ?? "x"
                return Data((custom ?? #"""
                    {"workbench_id":\#(workbenchID),"created":true,"path":"\#(worktree)","cwd":"\#(worktree)",
                     "branch":"wt/\#(name)","base":"a1b2c3d4e5f6","base_branch":"main","base_dirty":false,
                     "included":[],"include_warnings":[]}
                    """#).utf8)
            }
            return Data(#"""
                {"workbench_id":\#(workbenchID),"git_available":true,"git":true,"branch":"main","head":"a1b2c3d",
                 "dirty":false,"changes":0,"top_level":"/tmp/acme","git_dir":"/tmp/acme/.git",
                 "common_dir":"/tmp/acme/.git","status_ok":true,"status_error":""}
                """#.utf8)
        }
    }

    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var root: URL!
    private var processes: [FakeTerminalSession] = []
    private var center: TerminalCenter!

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchesViewModelPlacementTests-\(UUID().uuidString)"))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wt placement \(UUID().uuidString)",
                                                                             isDirectory: true)
        try FileManager.default.createDirectory(at: worktreeURL, withIntermediateDirectories: true)
        processes = []
        center = TerminalCenter { [weak self] in
            let process = FakeTerminalSession(pid: 0)
            self?.processes.append(process)
            return process
        }
        center.shell = { "/bin/zsh" }
        center.transcriptExists = { _ in false }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private var acme: String { root.appendingPathComponent("acme").path }
    private var worktreeURL: URL { root.appendingPathComponent("acme/.claude/worktrees/session-2", isDirectory: true) }
    private var worktree: String { worktreeURL.path }
    private var launches: [TerminalLaunch] { processes.flatMap(\.launches) }

    private func workbench(setup: String = "") async throws -> Int64 {
        let folder = acme
        return try await pool.write { db in
            let id = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            try db.execute(sql: "UPDATE projects SET worktree_setup = ? WHERE id = ?", arguments: [setup, id])
            return id
        }
    }

    private func makeVM(_ runner: PlacementRunner) async -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults,
                                      terminalCenter: center)
        vm.titleService = { _ in .init(title: "", written: false) }
        await vm.reload()
        return vm
    }

    /// A claude row of the workbench in `folder`, running in the center.
    @discardableResult
    private func liveRow(_ p: Int64, folder: String, branch: String? = nil) async throws -> TerminalSession {
        let row = try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: p, kind: .claude, title: "live", folderPath: folder,
                claudeSessionID: UUID().uuidString.lowercased(), worktreeBranch: branch, worktreeBase: branch.map { _ in "abc" }
            ))
        }
        center.start(row, fresh: true)
        XCTAssertTrue(center.liveAgentIDs.contains(row.id))
        return row
    }

    private func started(_ p: Int64) async throws -> [TerminalSession] {
        try await pool.read { try TerminalSessionQueries.fetchForWorkbench($0, projectID: p) }
            .filter { $0.title != "live" }
    }

    private func firstStarted(
        _ p: Int64, where match: (TerminalSession) -> Bool = { _ in true }
    ) async throws -> TerminalSession {
        let rows = try await started(p)
        return try XCTUnwrap(rows.first(where: match))
    }

    func testALoneSessionStartsInTheFolder() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)

        await vm.newSession(projectID: p)

        let row = try await firstStarted(p)
        XCTAssertEqual(row.folderPath, acme)
        XCTAssertNil(row.worktreeBranch)
        XCTAssertEqual(runner.createdNames, [])
        XCTAssertNil(vm.startNotice[p])
    }

    func testASecondSessionGetsAWorktree() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: acme)

        await vm.newSession(projectID: p)

        XCTAssertEqual(runner.createdNames, ["session-2"])
        let row = try await firstStarted(p)
        XCTAssertEqual(row.folderPath, worktree)
        XCTAssertEqual(row.worktreeBranch, "wt/session-2")
        XCTAssertEqual(row.worktreeBase, "a1b2c3d4e5f6")
        XCTAssertEqual(launches.last?.currentDirectory, worktree)
        XCTAssertNil(vm.startNotice[p])
    }

    func testAPlacedLiveSessionDoesNotOccupyTheFolder() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: worktree, branch: "wt/older")

        await vm.newSession(projectID: p)

        let row = try await firstStarted(p)
        XCTAssertEqual(row.folderPath, acme)
        XCTAssertNil(row.worktreeBranch)
        XCTAssertEqual(runner.createdNames, [])
    }

    func testOverrideFolderAndWorktree() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)

        await vm.newSession(projectID: p, worktree: .worktree)
        let placed = try await firstStarted(p)
        XCTAssertEqual(placed.folderPath, worktree, "a free folder, but the owner asked for a worktree")
        XCTAssertEqual(runner.createdNames.count, 1)

        try await liveRow(p, folder: acme)
        await vm.newSession(projectID: p, worktree: .folder)
        let rows = try await started(p)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first { $0.id != placed.id }?.folderPath, acme, "an occupied folder, but the owner asked for it")
        XCTAssertEqual(runner.createdNames.count, 1)
    }

    func testRefusedCreateFallsBackWithANote() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        runner.setCreateReply(#"{"workbench_id":1,"created":false,"refused":"unborn","refused_detail":""}"#)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: acme)

        await vm.newSession(projectID: p)

        let row = try await firstStarted(p)
        XCTAssertEqual(row.folderPath, acme)
        XCTAssertNil(row.worktreeBranch)
        XCTAssertEqual(vm.startNotice[p], "Started in the folder: unborn")
    }

    func testBaseDirtyShowsTheNote() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        runner.setCreateReply(#"""
            {"workbench_id":1,"created":true,"path":"\#(worktree)","cwd":"\#(worktree)","branch":"wt/session-2",
             "base":"abc","base_dirty":true}
            """#)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: acme)

        await vm.newSession(projectID: p)

        let row = try await firstStarted(p)
        XCTAssertEqual(row.folderPath, worktree)
        XCTAssertEqual(vm.startNotice[p], "The new worktree does not have the folder's uncommitted changes.")
    }

    func testAWorktreeWarningShowsTheFirstOne() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        runner.setCreateReply(#"""
            {"workbench_id":1,"created":true,"path":"\#(worktree)","cwd":"\#(worktree)","branch":"wt/session-2",
             "base":"abc","include_warnings":[".env: not copied"],"integration_error":"hooks failed"}
            """#)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: acme)

        await vm.newSession(projectID: p)

        let row = try await firstStarted(p)
        XCTAssertEqual(row.folderPath, worktree)
        XCTAssertEqual(vm.startNotice[p], "Worktree: .env: not copied")
    }

    func testConcurrentStartsSecondGetsWorktree() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)

        async let first: Void = vm.newSession(projectID: p)
        async let second: Void = vm.newSession(projectID: p)
        _ = await (first, second)

        let rows = try await started(p)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.folderPath)), [acme, worktree])
        XCTAssertEqual(runner.createdNames.count, 1)
    }

    func testSetupRunsOnlyOnAPlacedFirstLaunch() async throws {
        let p = try await workbench(setup: "make deps")
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        let setupEnv = "\(TerminalLaunch.setupCommandEnv)=make deps"

        await vm.newSession(projectID: p)
        let folderLaunch = try XCTUnwrap(launches.last)
        XCTAssertEqual(folderLaunch.currentDirectory, acme)
        XCTAssertFalse(folderLaunch.environment.contains(setupEnv))

        await vm.newSession(projectID: p)
        let placedLaunch = try XCTUnwrap(launches.last)
        XCTAssertEqual(placedLaunch.currentDirectory, worktree)
        XCTAssertTrue(placedLaunch.environment.contains(setupEnv))
        XCTAssertTrue(placedLaunch.args.last?.hasPrefix(TerminalLaunch.setupPrefix) ?? false)

        // A resume of the placed row never re-runs it.
        let placed = try await firstStarted(p) { $0.worktreeBranch != nil }
        await center.close(sessionID: placed.id)
        await vm.open(placed)
        let resumed = try XCTUnwrap(launches.last)
        XCTAssertEqual(resumed.currentDirectory, worktree)
        XCTAssertFalse(resumed.environment.contains(setupEnv))
        XCTAssertEqual(runner.createdNames.count, 1, "reopening a row never re-decides")
    }

    func testWorkOnItPassesTheTargetSlug() async throws {
        let p = try await workbench()
        let target = try await pool.write { try TestDatabase.insertWorkbenchTarget($0, projectID: p, text: "Fix the thing") }
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: acme)

        await vm.workOn(targetID: target, targetText: "Fix the thing")

        XCTAssertEqual(runner.createdNames, ["\(target)-fix-the-thing"])
        let row = try await firstStarted(p) { $0.targetID == target }
        XCTAssertEqual(row.folderPath, worktree)
    }

    func testAShellRowIsNeverPlaced() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        try await liveRow(p, folder: acme)

        await vm.newStandalone(kind: .shell, folder: URL(fileURLWithPath: acme))

        XCTAssertEqual(runner.createdNames, [])
    }

    /// A placed, stopped row whose worktree directory is `gone` or present.
    private func placedRow(_ p: Int64, gone: Bool) async throws -> TerminalSession {
        if gone { try FileManager.default.removeItem(at: worktreeURL) }
        let folder = worktree
        return try await pool.write { db in
            try TerminalSessionQueries.create(db, .init(
                projectID: p, kind: .claude, title: "placed", folderPath: folder,
                claudeSessionID: UUID().uuidString.lowercased(), worktreeBranch: "wt/session-2", worktreeBase: "abc"
            ))
        }
    }

    func testResumeOfACleanedUpWorktreeReAddsIt() async throws {
        let p = try await workbench(setup: "make deps")
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        let row = try await placedRow(p, gone: true)
        // The CLI re-adds the directory.
        let url = worktreeURL
        runner.onEnsure = { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

        await vm.open(row)

        let call = try XCTUnwrap(runner.ensureCalls.first)
        XCTAssertEqual(call[call.firstIndex(of: "--path").map { $0 + 1 }!], worktree)
        XCTAssertEqual(call[call.firstIndex(of: "--branch").map { $0 + 1 }!], "wt/session-2")
        let launch = try XCTUnwrap(launches.last)
        XCTAssertEqual(launch.currentDirectory, worktree)
        XCTAssertFalse(launch.environment.contains { $0.hasPrefix(TerminalLaunch.setupCommandEnv) }, "a resume never runs the setup command")
    }

    func testResumeWithTheBranchGoneIsUnavailable() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        runner.setEnsureReply(#"""
            {"workbench_id":1,"created":false,"path":"","cwd":"","branch":"","base":"","base_branch":"",
             "base_dirty":false,"included":[],"include_warnings":[],"refused":"unknown_branch"}
            """#)
        let vm = await makeVM(runner)
        let row = try await placedRow(p, gone: true)

        await vm.open(row)

        XCTAssertEqual(
            center.states[row.id],
            .unavailable("The worktree and its branch wt/session-2 were cleaned up — start a new session.")
        )
        XCTAssertTrue(launches.isEmpty)
    }

    func testResumeOfAnExistingWorktreeCallsNothing() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        let vm = await makeVM(runner)
        let row = try await placedRow(p, gone: false)

        await vm.open(row)

        XCTAssertTrue(runner.ensureCalls.isEmpty)
        XCTAssertEqual(launches.last?.currentDirectory, worktree)
    }

    func testResumeThatCannotRestoreIsUnavailable() async throws {
        let p = try await workbench()
        let runner = PlacementRunner(workbenchID: p, worktree: worktree)
        runner.setEnsureReply(#"""
            {"workbench_id":1,"created":false,"path":"","cwd":"","branch":"","base":"","base_branch":"",
             "base_dirty":false,"included":[],"include_warnings":[],"refused":"path_in_use","refused_detail":"busy"}
            """#)
        let vm = await makeVM(runner)
        let row = try await placedRow(p, gone: true)

        await vm.open(row)

        XCTAssertEqual(center.states[row.id], .unavailable("The worktree \(worktree) could not be restored: busy"))
        XCTAssertTrue(launches.isEmpty)
    }
}
