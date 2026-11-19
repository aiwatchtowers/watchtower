import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Remove from Bench… and Locate… on a FILES root (#2003, spec §6.3): the
/// refusals come before the confirmation, the write is Go's
/// (`workbench folder remove|locate`), and Go's own refusal after the
/// confirmation (spec §7 row 4) is shown as the Desktop's.
@MainActor
final class WorkbenchFolderRemoveTests: XCTestCase {
    private var pool: DatabasePool!
    private var path = ""
    private var defaults: UserDefaults!
    private var bench: Int64 = 0
    private var home: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "WorkbenchFolderRemoveTests-\(UUID().uuidString)"))
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

    private func addFolder(_ path: String, name: String, position: Int) throws -> Int64 {
        try pool.write { [bench] db in
            try db.execute(sql: """
                INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name)
                VALUES (?, ?, ?, 'owner', ?)
                """, arguments: [bench, path, position, name])
            return db.lastInsertedRowID
        }
    }

    private func addSession(folderID: Int64?, kind: TerminalSession.Kind = .claude) throws -> Int64 {
        try pool.write { [bench] db in
            try TerminalSessionQueries.create(db, .init(
                projectID: bench, kind: kind, title: "Fix", folderPath: "/tmp/acme-hub",
                claudeSessionID: kind == .shell ? nil : UUID().uuidString, workbenchFolderID: folderID
            )).id
        }
    }

    private func makeVM(_ runner: BenchFoldersGitRunner, live: Set<Int64> = []) async -> WorkbenchesViewModel {
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults)
        vm.folderExists = { _ in true }
        vm.liveSessionIDs = { live }
        await vm.reload()
        await vm.loadSessions(projectID: bench)
        return vm
    }

    private func runner() -> BenchFoldersGitRunner {
        BenchFoldersGitRunner(folders: [.init(id: home, path: "/tmp/acme-app", branch: "main")], homeID: home)
    }

    private func folder(_ vm: WorkbenchesViewModel, _ id: Int64) throws -> WorkbenchFolder {
        try XCTUnwrap(vm.benchFolders[bench]?.folder(id))
    }

    private static func folderJSON(id: Int64, path: String, name: String, installed: Bool = true) -> String {
        #"{"id":\#(id),"path":"\#(path)","name":"\#(name)","position":1,"home":false,"installed":\#(installed),"removed":false}"#
    }

    // MARK: - Remove from Bench…

    func testRemoveRefusedWhileSessionsRun() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let first = try addSession(folderID: hub)
        let second = try addSession(folderID: hub)
        let shell = try addSession(folderID: hub, kind: .shell)
        let elsewhere = try addSession(folderID: home)
        let vm = await makeVM(runner(), live: [first, shell, elsewhere])

        let one = vm.removeDialog(try folder(vm, hub))
        XCTAssertEqual(one.title, "Can’t remove hub from the bench")
        XCTAssertEqual(one.message, "1 session is running in hub. Finish it first.", "shells and other folders' sessions never count")
        XCTAssertFalse(one.confirms)

        vm.liveSessionIDs = { [first, second] }
        XCTAssertEqual(vm.removeDialog(try folder(vm, hub)).message, "2 sessions are running in hub. Finish them first.")
    }

    /// A row with no folder is the home folder's (Go's `SessionRowsSQL`).
    func testRemoveCountsFolderlessRowsAsHome() async throws {
        _ = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let legacy = try addSession(folderID: home)
        try await pool.write { db in
            try db.execute(sql: "UPDATE terminal_sessions SET workbench_folder_id = NULL WHERE id = ?", arguments: [legacy])
        }
        let vm = await makeVM(runner(), live: [legacy])
        XCTAssertEqual(vm.removeDialog(try folder(vm, home)).message, "1 session is running in acme-app. Finish it first.")
    }

    func testRemoveRefusedForTheLastFolder() async throws {
        let vm = await makeVM(runner())
        let dialog = vm.removeDialog(try folder(vm, home))
        XCTAssertEqual(dialog.title, "Can’t remove acme-app from the bench")
        XCTAssertEqual(dialog.message, "A workbench needs at least one folder.")
        XCTAssertFalse(dialog.confirms)
    }

    func testRemoveConfirmThenCLI() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner()
        runner.answer("folder remove", .success(Data(
            #"{"ok":true,"folder":\#(Self.folderJSON(id: hub, path: "/tmp/acme-hub", name: "hub")),"install":{"ok":true,"error":""}}"#.utf8)))
        let vm = await makeVM(runner)
        let dialog = vm.removeDialog(try folder(vm, hub))
        XCTAssertEqual(dialog.title, "Remove hub from the bench?")
        XCTAssertEqual(dialog.message, "Watchtower's install in this folder is removed. Your files and git are not touched.")
        XCTAssertTrue(dialog.confirms)
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["workbench", "folder", "remove"]) }, "nothing before the confirmation")

        let refused = await vm.removeFromBench(try folder(vm, hub))

        XCTAssertNil(refused)
        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "folder", "remove"]) },
                       ["workbench", "folder", "remove", "--workbench", String(bench), "--folder", String(hub), "--json"])
        XCTAssertNil(vm.putOnBenchErrors[bench])
    }

    /// Spec §7 row 4: a session started between the dialog and the remove —
    /// Go refuses inside its transaction; the owner sees the refusal.
    func testRemoveRefusedByGoAfterTheConfirmation() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner()
        runner.answer("folder remove", .success(Data(
            #"{"ok":false,"error_code":"sessions_running","error":"sessions_running: 1 session is running in hub. Finish it first."}"#.utf8)))
        let vm = await makeVM(runner)

        let refused = await vm.removeFromBench(try folder(vm, hub))

        XCTAssertEqual(refused, WorkbenchFolderPresentation.removeRefusedSessions(name: "hub", count: 1))
    }

    // MARK: - Locate…

    func testLocateRepointsAndReinstalls() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner()
        let moved = Self.folderJSON(id: hub, path: "/tmp/moved/hub", name: "hub", installed: false)
        runner.answer("folder locate", .success(Data(
            #"{"ok":true,"folder":\#(moved),"install":{"ok":false,"error":"boom"}}"#.utf8)))
        let vm = await makeVM(runner)
        vm.folderExists = { $0 != "/tmp/acme-hub" }
        await vm.reload()
        XCTAssertEqual(vm.missingFolders[bench], [hub])
        try await pool.write { db in
            try db.execute(sql: "UPDATE workbench_folders SET folder_path = '/tmp/moved/hub' WHERE id = ?", arguments: [hub])
        }

        await vm.locateFolder(try folder(vm, hub), to: URL(fileURLWithPath: "/tmp/moved/hub"))

        XCTAssertEqual(runner.invocations.first { $0.starts(with: ["workbench", "folder", "locate"]) },
                       ["workbench", "folder", "locate", "--workbench", String(bench), "--folder", String(hub),
                        "--to", "/tmp/moved/hub", "--json"])
        XCTAssertNil(vm.missingFolders[bench], "the root is found again")
        XCTAssertEqual(vm.folderInstalled[bench]?[hub], false, "a failed reinstall shows the install icon and Retry")
        XCTAssertNil(vm.putOnBenchErrors[bench])
    }

    func testLocateRefusedSaysWhy() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner()
        runner.answer("folder locate", .success(Data(
            #"{"ok":false,"error_code":"nested","error":"nested: /tmp/acme-app/hub is inside acme-app."}"#.utf8)))
        let vm = await makeVM(runner)

        await vm.locateFolder(try folder(vm, hub), to: URL(fileURLWithPath: "/tmp/acme-app/hub"))

        XCTAssertEqual(vm.putOnBenchErrors[bench], "Couldn’t locate hub: /tmp/acme-app/hub is inside acme-app.")
    }

    /// A bench whose only folder moved still shows its root row (Folder not
    /// found + Locate…); Remove is off for the last folder. A healthy single
    /// folder keeps today's tree.
    func testOnlyFolderMissingShowsItsRootWithLocate() async throws {
        let vm = await makeVM(runner())
        let fetched = try await pool.read { [bench] in try WorkbenchQueries.fetch($0, id: bench) }
        let project = try XCTUnwrap(fetched)
        XCTAssertFalse(WorkbenchesViewModel.showsRootRows(vm.filesRoots(project: project, active: project.mainCodeRoot)))

        vm.folderExists = { _ in false }
        await vm.reload()
        let roots = vm.filesRoots(project: project, active: project.mainCodeRoot)
        XCTAssertEqual(roots.map(\.state), [.notFound])
        XCTAssertTrue(WorkbenchesViewModel.showsRootRows(roots), "the row carries Locate…")
        XCTAssertFalse(vm.canRemoveFolder(projectID: bench), "the only folder cannot leave the bench")

        _ = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        await vm.reload()
        XCTAssertTrue(vm.canRemoveFolder(projectID: bench))
    }

    /// Locate… asks Open Folder…'s TCC question first for a sensitive place.
    func testLocateIntoASensitiveLocationAsksFirst() async throws {
        let hub = try addFolder("/tmp/acme-hub", name: "hub", position: 1)
        let runner = runner()
        let vm = await makeVM(runner)
        let target = URL(fileURLWithPath: "/Users/owner/Documents/hub")

        let step = await vm.locate(try folder(vm, hub), to: target, home: "/Users/owner")

        let location = try XCTUnwrap(WorkbenchFolderPolicy.tccSensitiveLocation(path: target.path, home: "/Users/owner"))
        XCTAssertEqual(step, .confirmLocation(location))
        XCTAssertFalse(runner.invocations.contains { $0.starts(with: ["workbench", "folder", "locate"]) }, "nothing before the owner confirms")
    }

    // MARK: - Repair (parked from Task 12)

    /// A folder set up before the outside-bench hook is offered Repair; an
    /// older CLI without the key has nothing to install.
    func testMissingOutsideTouchHookNeedsRepair() throws {
        let base = #""skill":"unchanged","hook":true,"stop_hook":true,"state_hooks":true,"mcp":true"#
        let missing = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data("{\(base),\"outside_touch\":false}".utf8))
        XCTAssertFalse(missing.outsideTouch)
        XCTAssertTrue(missing.claudeNeedsRepair)
        XCTAssertTrue(missing.repairHelp.contains("outside-bench hook missing"), missing.repairHelp)
        let older = try JSONDecoder().decode(WorkbenchInstallStatus.self, from: Data("{\(base)}".utf8))
        XCTAssertTrue(older.outsideTouch)
        XCTAssertFalse(older.claudeNeedsRepair)
    }
}
