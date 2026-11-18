import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// FILES with a root per bench folder, Put on the Bench…, Open Folder… on a
/// non-home folder and each root's own git status (#2003, spec §6.1, §6.2,
/// §6.8, §7 rows 2 and "folder missing at launch").
@MainActor
final class WorkbenchesViewModelFoldersTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var defaults: UserDefaults!
    private var bench: Int64 = 0
    private var home: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchFoldersTests-\(UUID().uuidString)"))
        (bench, home) = try pool.write { db in
            let bench = try TestDatabase.insertWorkbench(db, name: "acme", folder: "/tmp/acme-app")
            return (bench, try XCTUnwrap(WorkbenchFolderQueries.homeFolderID(db, workbenchID: bench)))
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    // MARK: - Fixtures

    @discardableResult
    private func addFolder(_ path: String, name: String, position: Int, to bench: Int64? = nil) throws -> Int64 {
        let bench = bench ?? self.bench
        return try pool.write { db in
            try db.execute(sql: """
                INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
                VALUES (?, ?, ?, 'owner', ?)
                """, arguments: [bench, path, position, name])
            return db.lastInsertedRowID
        }
    }

    private func project() throws -> Workbench {
        try XCTUnwrap(try pool.read { try WorkbenchQueries.fetch($0, id: self.bench) })
    }

    private func makeVM(_ runner: any CLIRunnerProtocol) -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.folderExists = { _ in true }
        vm.makeGitWatcher = { gitDir, commonDir, onChange in
            WorkbenchesViewModelGitTests.FakeWatcher(gitDir: gitDir, commonDir: commonDir, onChange: onChange)
        }
        vm.gitPollSleep = { _ in await parkUntilCancelled() }
        vm.gitNotificationCenter = NotificationCenter()
        return vm
    }

    private func runner(_ extra: [BenchFoldersGitRunner.Folder] = []) -> BenchFoldersGitRunner {
        BenchFoldersGitRunner(folders: [.init(id: home, path: "/tmp/acme-app", branch: "main")] + extra, homeID: home)
    }

    private static func folderJSON(id: Int64, path: String, name: String, installed: Bool = true) -> String {
        #"{"id":\#(id),"path":"\#(path)","name":"\#(name)","position":1,"home":false,"installed":\#(installed),"removed":false}"#
    }

    // MARK: - FILES roots

    func testOneFolderShowsOneRootAndTheHint() async throws {
        let vm = makeVM(runner())
        await vm.reload()
        let project = try project()
        let roots = vm.filesRoots(project: project, active: project.mainCodeRoot)
        XCTAssertEqual(roots.map(\.name), ["acme-app"], "one folder: one root, today's tree")
        XCTAssertEqual(roots.first?.root, project.mainCodeRoot)
        XCTAssertEqual(roots.first?.isExpanded, true)
        XCTAssertEqual(WorkbenchFolderPresentation.hint, "Task touches another repo? Put on the Bench…")
    }

    func testRootsInPositionOrder() async throws {
        let site = try addFolder("/tmp/acme-site", name: "site", position: 2)
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let vm = makeVM(runner())
        await vm.reload()
        let project = try project()
        let roots = vm.filesRoots(project: project, active: project.mainCodeRoot)
        XCTAssertEqual(roots.map(\.id), [home, hub, site])
        XCTAssertEqual(roots.map(\.name), ["acme-app", "hub", "site"])
        XCTAssertEqual(roots.map(\.isExpanded), [true, false, false], "the active folder's root is open")
        XCTAssertEqual(roots[1].root.folderID, hub)
        XCTAssertEqual(roots[1].root.defaultsKeySuffix, ".f\(hub)")

        vm.toggleFolderRoot(hub, projectID: bench)
        XCTAssertEqual(vm.filesRoots(project: project, active: project.mainCodeRoot).map(\.isExpanded), [true, true, false])
    }

    func testMissingFolderRootSaysFolderNotFound() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner([.init(id: hub, path: "/tmp/acme-hub", branch: "main")])
        let vm = makeVM(runner)
        vm.folderExists = { $0 != "/tmp/acme-hub" }
        await vm.reload()
        let project = try project()
        let roots = vm.filesRoots(project: project, active: project.mainCodeRoot)
        XCTAssertEqual(roots[1].state, .notFound)
        XCTAssertEqual(roots[1].state.trailing, "Folder not found")
        XCTAssertNil(roots[1].branchLine)
        XCTAssertFalse(roots[1].isExpanded, "a folder that is gone has no tree")
        XCTAssertTrue(vm.otherFolderRoots(workbenchID: bench).isEmpty, "a missing folder is never polled")
    }

    // MARK: - Open Folder…

    func testOpenFolderOnANonHomeFolderOpensItsBench() async throws {
        try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let vm = makeVM(runner())
        let outcome = await vm.openFolder(URL(fileURLWithPath: "/tmp/acme-hub"), home: "/Users/owner")
        XCTAssertEqual(outcome, .opened)
        XCTAssertEqual(vm.selectedWorkbenchID, bench)
        XCTAssertEqual(vm.workbenchID(boundTo: URL(fileURLWithPath: "/private/tmp/acme-hub/")), bench,
                       "any spelling of the folder, as for home")
    }

    func testOpenFolderTCCConfirmationUnchanged() async throws {
        let runner = runner()
        let vm = makeVM(runner)
        let picked = URL(fileURLWithPath: "/Users/owner/Documents/billing")
        let open = await vm.openFolder(picked, home: "/Users/owner")
        let put = await vm.putOnBench(picked, projectID: bench, home: "/Users/owner")
        guard case let .confirmLocation(location) = open else { return XCTFail("Open Folder… asks first: \(open)") }
        XCTAssertEqual(put, .confirmLocation(location), "Put on the Bench… asks the same question")
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["workbench", "folder", "add"]) },
                       "nothing is added before the owner confirms")
    }

    // MARK: - Put on the Bench…

    func testPutOnBenchInstallFailureShowsRetry() async throws {
        // Go's write: the folder is on the bench, its install failed.
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner([.init(id: hub, path: "/tmp/acme-hub", branch: "main")])
        runner.answer("folder add", .success(Data(#"""
            {"ok":true,"folder":\#(Self.folderJSON(id: hub, path: "/tmp/acme-hub", name: "hub", installed: false)),
             "install":{"ok":false,"error":"settings.json is not writable"}}
            """#.utf8)))
        let vm = makeVM(runner)
        let step = await vm.putOnBench(URL(fileURLWithPath: "/tmp/acme-hub"), projectID: bench, home: "/Users/owner")
        XCTAssertEqual(step, .done)
        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "folder", "add"]) },
                       ["workbench", "folder", "add", "--workbench", String(bench), "--folder", "/tmp/acme-hub",
                        "--added-by", "owner", "--json"])
        let project = try project()
        let root = try XCTUnwrap(vm.filesRoots(project: project, active: project.mainCodeRoot).first { $0.id == hub })
        XCTAssertEqual(root.state, .installMissing, "the folder stays on the bench with the install icon and Retry")
        XCTAssertTrue(root.isHighlighted)
        XCTAssertTrue(root.isExpanded)
        XCTAssertNil(vm.putOnBenchErrors[bench], "a failed install is no refusal")

        await vm.retryFolderInstall(projectID: bench)
        XCTAssertTrue(runner.invocations.contains { $0.starts(with: ["workbench", "resync"]) }, "Retry re-runs setup")
        XCTAssertTrue(runner.invocations.contains { $0.starts(with: ["workbench", "folder", "list"]) },
                      "then reads the install flags again")
    }

    func testAlreadyHereHighlightsThatRoot() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner()
        runner.answer("folder add", .success(Data(#"""
            {"ok":false,"error_code":"already_here","error":"hub is already on this bench.",
             "folder":\#(Self.folderJSON(id: hub, path: "/tmp/acme-hub", name: "hub"))}
            """#.utf8)))
        let vm = makeVM(runner)
        await vm.addFolderToBench(URL(fileURLWithPath: "/tmp/acme-hub"), projectID: bench)
        XCTAssertEqual(vm.highlightedFolderRoot[bench], hub)
        XCTAssertNil(vm.putOnBenchErrors[bench])
    }

    // MARK: - Merging benches (§6.13)

    /// Another bench "tools" on /tmp/billing with two targets.
    private func toolsBench() throws -> Int64 {
        try pool.write { db in
            let tools = try TestDatabase.insertWorkbench(db, name: "tools", folder: "/tmp/billing")
            for text in ["one", "two"] { try TestDatabase.insertWorkbenchTarget(db, projectID: tools, text: text) }
            return tools
        }
    }

    private static func otherBenchJSON(_ tools: Int64) -> Result<Data, Error> {
        .success(Data(#"""
            {"ok":false,"error_code":"other_bench","error":"other_bench: /tmp/billing is on the workbench \"tools\".",
             "other_bench":{"id":\#(tools),"name":"tools"}}
            """#.utf8))
    }

    func testOtherBenchOnAddOpensMergeConfirm() async throws {
        let tools = try toolsBench()
        let runner = runner()
        runner.answer("folder add", Self.otherBenchJSON(tools))
        let vm = makeVM(runner)
        await vm.addFolderToBench(URL(fileURLWithPath: "/tmp/billing"), projectID: bench)
        XCTAssertNil(vm.putOnBenchErrors[bench], "no refusal: the merge is offered")
        let offer = try XCTUnwrap(vm.mergeOffer)
        XCTAssertEqual(offer.title, "Merge “tools” into “acme”?")
        XCTAssertEqual(offer.text, "tools's board (2 targets), asks and sessions move to acme, and tools leaves the workbench list. "
            + "Folders that move: billing.")

        vm.cancelMerge()
        XCTAssertNil(vm.mergeOffer)
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["workbench", "merge"]) }, "Cancel changes nothing")
    }

    func testMergeRefusedShowsTheCount() async throws {
        let tools = try toolsBench()
        let runner = runner()
        runner.answer("folder add", Self.otherBenchJSON(tools))
        runner.answer("merge --from", .success(Data(#"""
            {"ok":false,"error_code":"sessions_running","error":"sessions_running: 2 sessions are running in tools. Finish them first.",
             "running":2,"moved_folders":[],"targets":0,"reinstall":{"ok":false,"failed":[]}}
            """#.utf8)))
        let vm = makeVM(runner)
        await vm.addFolderToBench(URL(fileURLWithPath: "/tmp/billing"), projectID: bench)
        await vm.confirmMerge()
        let refusal = try XCTUnwrap(vm.mergeRefusal)
        XCTAssertEqual(refusal.title, "Can’t merge “tools” yet")
        XCTAssertEqual(refusal.text, "2 sessions are running in tools. Finish them first.")
        XCTAssertNil(vm.putOnBenchErrors[bench])
        vm.dismissMergeRefusal()
        XCTAssertNil(vm.mergeRefusal)
    }

    /// §7 "merge", Swift half: a reinstall that failed in a moved folder
    /// leaves its FILES root with the install icon and Retry; the merge
    /// itself is done.
    func testReinstallFailureShowsRetry() async throws {
        let tools = try toolsBench()
        let runner = runner()
        runner.answer("folder add", Self.otherBenchJSON(tools))
        let vm = makeVM(runner)
        await vm.addFolderToBench(URL(fileURLWithPath: "/tmp/billing"), projectID: bench)
        // Go's merge: the folder row moves to this bench, its reinstall fails.
        let moved = try await pool.write { [bench] db in
            let id = try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM workbench_folders WHERE workbench_id = ?", arguments: [tools]))
            try db.execute(sql: "UPDATE workbench_folders SET workbench_id = ?, position = 1 WHERE id = ?", arguments: [bench, id])
            try db.execute(sql: "UPDATE targets SET project_id = ? WHERE project_id = ?", arguments: [bench, tools])
            try db.execute(sql: "DELETE FROM projects WHERE id = ?", arguments: [tools])
            return id
        }
        runner.answer("merge --from", .success(Data(#"""
            {"ok":true,"error_code":"","error":"","targets":2,
             "moved_folders":[\#(Self.folderJSON(id: moved, path: "/tmp/billing", name: "billing", installed: false))],
             "reinstall":{"ok":false,"failed":[{"path":"/tmp/billing","error":"settings.json is not writable"}]}}
            """#.utf8)))
        await vm.confirmMerge()

        XCTAssertNil(vm.putOnBenchErrors[bench])
        let project = try project()
        let root = try XCTUnwrap(vm.filesRoots(project: project, active: project.mainCodeRoot).first { $0.id == moved })
        XCTAssertEqual(root.state, .installMissing, "the install icon with Retry")
        XCTAssertTrue(root.isHighlighted, "the folder put on the bench is pointed at")
        XCTAssertFalse(vm.summaries.contains { $0.id == tools }, "the merged bench left the list")
    }

    func testAnAddWithoutAFolderIsNoFailure() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(#"{"ok":true}"#.utf8)))
        let vm = makeVM(runner)
        await vm.addFolderToBench(URL(fileURLWithPath: "/tmp/acme-hub"), projectID: bench)
        XCTAssertNil(vm.putOnBenchErrors[bench], "ok without a folder is an add, not “Couldn’t put …: ”")
    }

    func testARefusalWithoutWordsStillSaysSomething() async throws {
        let runner = runner()
        runner.answer("folder add", .success(Data(#"{"ok":false}"#.utf8)))
        let vm = makeVM(runner)
        await vm.addFolderToBench(URL(fileURLWithPath: "/tmp/billing"), projectID: bench)
        XCTAssertEqual(vm.putOnBenchErrors[bench], "Couldn’t put billing on the bench: the command gave no reason.")
    }

    // MARK: - The selected FILES root

    /// A file opened from another folder's root puts that root in the Files
    /// pane and under the branch crumb, switch and fetch (spec §6.8), until
    /// the page's session changes.
    func testOpeningAFileInAnotherRootMakesItThePagesRoot() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let session = try await pool.write { [bench] db in
            try TerminalSessionQueries.create(db, .init(
                projectID: bench, kind: .claude, title: "s", folderPath: "/tmp/acme-app",
                claudeSessionID: UUID().uuidString.lowercased()
            ))
        }
        let runner = runner([.init(id: hub, path: "/tmp/acme-hub", branch: "feature/hub")])
        runner.answer("git switch", .success(Data(
            #"{"workbench_id":\#(bench),"branch":"feature/x","switched":true,"status":{}}"#.utf8)))
        let vm = makeVM(runner)
        let project = try project()
        await vm.reload()
        _ = await vm.loadSessions(projectID: bench)
        let hubRoot = try vm.folderRoot(XCTUnwrap(vm.benchFolders[bench]?.folder(hub)))

        // No session on the page: the Files pane follows the root.
        vm.selectFilesRoot(hubRoot, project: project)
        XCTAssertEqual(vm.activeCodeRoot(project: project), hubRoot)
        XCTAssertEqual(vm.filesRoots(project: project, active: hubRoot).map(\.isExpanded), [true, true],
                       "the folder it left stays open")
        await vm.startGitWatching(project: project)
        await vm.followGitRoot(vm.activeCodeRoot(project: project))
        await vm.switchBranch("feature/x", project: project)
        let switched = try XCTUnwrap(runner.invocations.last { $0.starts(with: ["workbench", "git", "switch"]) })
        XCTAssertTrue(switched.contains("--workbench-folder") && switched.contains(String(hub)), "the switch runs in hub")

        // A session on the page: its own root again until a file of another
        // root is opened under it.
        var layout = WorkspaceLayout.default
        layout.primary = .session(session.id)
        vm.setLayout(layout, projectID: bench)
        XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot, "a session switch drops the choice")
        vm.selectFilesRoot(hubRoot, project: project)
        XCTAssertEqual(vm.activeCodeRoot(project: project), hubRoot)
        vm.selectFilesRoot(project.mainCodeRoot, project: project)
        XCTAssertEqual(vm.activeCodeRoot(project: project), project.mainCodeRoot, "the session's own root clears it")
        XCTAssertNil(vm.selectedFilesRoot[bench])
        vm.stopGitWatching(projectID: bench)
    }

    // MARK: - Git per folder

    func testEachRootPollsItsOwnStatus() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let site = try addFolder("/tmp/acme-site", name: "site", position: 2)
        let runner = runner([.init(id: hub, path: "/tmp/acme-hub", branch: "feature/hub"),
                             .init(id: site, path: "/tmp/acme-site", branch: "main")])
        let vm = makeVM(runner)
        vm.isTabOnScreen = { true }
        var sleeps: [Duration] = []
        // The first wait ends when the test says so (after the first reads),
        // the next one never: exactly one poll tick.
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        vm.gitPollSleep = { duration in
            sleeps.append(duration)
            guard sleeps.count == 1 else { return await parkUntilCancelled() }
            for await _ in ticks { break }
        }
        let project = try project()
        await vm.startGitWatching(project: project)
        tick.yield()
        let folderOf = { (args: [String]) in args.firstIndex(of: "--workbench-folder").map { args[$0 + 1] } }
        await runner.until { reads in
            reads.filter { $0.starts(with: ["workbench", "git", "status"]) && folderOf($0) == String(site) }.count >= 2
        }
        let reads = runner.statusReads
        for (id, name) in [(hub, "hub"), (site, "site")] {
            XCTAssertEqual(reads.filter { folderOf($0) == String(id) }.count, 2, "\(name): the first read and one poll")
        }
        XCTAssertEqual(reads.filter { folderOf($0) == nil }.count, 2, "home keeps its argv: no --workbench-folder")
        XCTAssertEqual(sleeps.first, WorkbenchesViewModel.gitPollInterval)
        XCTAssertEqual(WorkbenchesViewModel.gitPollInterval, .seconds(15), "the existing cadence")

        let roots = vm.filesRoots(project: project, active: project.mainCodeRoot)
        XCTAssertEqual(roots.map(\.branchLine), ["⎇ main", "⎇ feature/hub", "⎇ main"], "each root shows its own branch")
        vm.stopGitWatching(projectID: bench)
    }

    func testProj10_HeaderCrumbFollowsTheActiveSessionsFolder() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let session = try await pool.write { [bench] db in
            try TerminalSessionQueries.create(db, .init(
                projectID: bench, kind: .claude, title: "s", folderPath: "/tmp/acme-hub",
                claudeSessionID: UUID().uuidString.lowercased(), workbenchFolderID: hub
            ))
        }
        let runner = runner([.init(id: hub, path: "/tmp/acme-hub", branch: "feature/hub")])
        runner.answer("git switch", .success(Data(
            #"{"workbench_id":\#(bench),"branch":"feature/x","switched":true,"status":{}}"#.utf8)))
        let vm = makeVM(runner)
        let project = try project()
        await vm.reload()
        _ = await vm.loadSessions(projectID: bench)
        var layout = WorkspaceLayout.default
        layout.primary = .session(session.id)
        vm.setLayout(layout, projectID: bench)

        let root = vm.activeCodeRoot(project: project)
        let hubFolder = try XCTUnwrap(vm.benchFolders[bench]?.folder(hub))
        XCTAssertEqual(root, CodeRoot(folder: hubFolder, homeFolderID: home), "the page works in the session's folder")
        await vm.startGitWatching(project: project)
        await vm.followGitRoot(root)
        XCTAssertEqual(vm.gitStatus[root]?.branch, "feature/hub", "the crumb shows hub's branch")
        XCTAssertEqual(vm.gitStatus[bench]?.branch, "main", "home's entry is its own")

        await vm.switchBranch("feature/x", project: project)
        let switched = try XCTUnwrap(runner.invocations.last { $0.starts(with: ["workbench", "git", "switch"]) })
        XCTAssertEqual(switched, ["workbench", "git", "switch", "--workbench", String(bench), "--branch", "feature/x",
                                  "--workbench-folder", String(hub), "--json"])
        vm.stopGitWatching(projectID: bench)
    }
}
