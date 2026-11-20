import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Spec 2026-11-18 §6.4/§6.6 through the view model: every start entry point
/// sends its context's folder to `workbench session start --folder` (home
/// sends none), the worktree reason reads the start folder's git, and the
/// prompt notice's Dismiss goes through the CLI. Go's start is the scripted
/// runner; the session host is a fake transport (as StartNewSessionViaCLITests).
@MainActor
final class NewSessionFolderStartTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var defaults: UserDefaults!
    private var transports: [FakeSessionHostTransport] = []
    private var center: TerminalCenter!
    private var client: SessionHostClient!
    private var runner: ScriptedSessionStartRunner!
    private var vm: WorkbenchesViewModel!
    private var projectID: Int64 = 0
    private var home: Int64 = 0
    private var hub: Int64 = 0
    private var site: Int64 = 0
    private var old: Int64 = 0

    override func setUp() async throws {
        try await super.setUp()
        (pool, path) = try TestDatabase.createPool()
        defaults = try XCTUnwrap(UserDefaults(suiteName: "NewSessionFolderStartTests-\(UUID().uuidString)"))
        transports = []
        center = TerminalCenter { FakeTerminalSession() }
        center.shell = { "/bin/zsh" }
        client = SessionHostClient(socketPath: "/tmp/wt-test.sock", cliPath: { nil }, makeTransport: { [weak self] _ in
            let transport = FakeSessionHostTransport()
            self?.transports.append(transport)
            return transport
        })
        let running = await client.ensureRunning()
        XCTAssertTrue(running)
        center.sessionHost = client
        let folder = FileManager.default.temporaryDirectory.path
        (projectID, home, hub, site, old) = try await pool.write { db in
            let bench = try TestDatabase.insertWorkbench(db, name: "acme", folder: folder)
            let home = try XCTUnwrap(WorkbenchFolderQueries.homeFolderID(db, workbenchID: bench))
            func add(_ name: String, _ position: Int, removed: Bool = false) throws -> Int64 {
                try db.execute(sql: """
                    INSERT INTO workbench_folders (workbench_id, folder_path, position, added_by, name, removed_at)
                    VALUES (?, ?, ?, 'owner', ?, ?)
                    """, arguments: [bench, "/tmp/acme-\(name)", position, name, removed ? "2026-11-18T10:00:00Z" : nil])
                return db.lastInsertedRowID
            }
            return (bench, home, try add("hub", 1), try add("site", 2), try add("old", 3, removed: true))
        }
        runner = ScriptedSessionStartRunner(pool: pool)
        vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: runner), defaults: defaults, terminalCenter: center)
        vm.now = { Date(timeIntervalSince1970: 1_760_000_000) }
        vm.goSessionStart = GoSessionStartWait(poll: .milliseconds(1), deadline: .seconds(5)) { [weak self] _ in
            guard let self, let id = runner.startedIDs.last else { return }
            if !control.listed.contains(where: { $0.row == id }) {
                control.listed.append(SessionHostSessionInfo(row: id, run: "run-\(id)", pid: 4242,
                                                             startedAtMs: 1_760_000_000_000, exited: false, code: nil))
            }
            await Task.yield()
        }
        await vm.loadBenchFolders(projectID: projectID)
        vm.selectedWorkbenchID = projectID
    }

    override func tearDown() async throws {
        for id in center.liveIDs { (center.process(for: id) as? HostedTerminalSession)?.detachFromHost() }
        TestDatabase.cleanup(path: path)
        try await super.tearDown()
    }

    private var control: FakeSessionHostTransport { transports[0] }

    /// The `--folder` of the latest start; nil when it sent none (home).
    private var lastFolder: String? {
        guard let args = runner.invocations.last(where: { $0.starts(with: ["workbench", "session", "start"]) }) else {
            XCTFail("no start ran")
            return nil
        }
        return args.firstIndex(of: "--folder").map { args[$0 + 1] }
    }

    private func target(folder: Int64?) async throws -> Int64 {
        let projectID = projectID
        return try await pool.write { db in
            let id = try TestDatabase.insertWorkbenchTarget(db, projectID: projectID, text: "Export")
            try db.execute(sql: "UPDATE targets SET workbench_folder_id = ? WHERE id = ?", arguments: [folder, id])
            return id
        }
    }

    private func bench() throws -> BenchFolders { try XCTUnwrap(vm.benchFolders[projectID]) }

    func testEveryStartEntryPointPassesTheContextFolder() async throws {
        // ⌘T with no session on screen: the FILES root the owner opened.
        vm.toggleFolderRoot(hub, projectID: projectID)
        await vm.newSessionOnPage()
        XCTAssertEqual(lastFolder, String(hub), "⌘T: the opened root")

        // ⌘T in a hub session (the root closed again): the session's folder.
        vm.toggleFolderRoot(hub, projectID: projectID)
        await vm.newSessionOnPage()
        XCTAssertEqual(lastFolder, String(hub), "⌘T: the current session's folder")

        // A New Session (+) item: its folder; home sends no flag.
        await vm.newSessionOnPage(folder: .menu(folderID: home))
        XCTAssertNil(lastFolder, "home: today's argv")
        await vm.newSessionOnPage()
        XCTAssertNil(lastFolder, "⌘T in a home session")

        // New Session Here on a FILES root.
        let siteFolder = try XCTUnwrap(try bench().folder(site))
        await vm.newSession(projectID: projectID, folder: .filesRoot(vm.folderRoot(siteFolder)))
        XCTAssertEqual(lastFolder, String(site))

        // Work on It: the target's folder; none → home.
        let inHub = try await target(folder: hub)
        await vm.workOn(targetID: inHub, targetText: "Export", projectID: projectID)
        XCTAssertEqual(lastFolder, String(hub))
        let inNone = try await target(folder: nil)
        await vm.workOn(targetID: inNone, targetText: "Export", projectID: projectID)
        XCTAssertNil(lastFolder)
    }

    /// ⌘T with Files the only pane on screen while a home session still runs
    /// off screen: the root the owner opened, not that session's folder.
    func testShortcutWithOnlyFilesShowingUsesTheOpenedRoot() async throws {
        await vm.newSessionOnPage(folder: .menu(folderID: home))
        XCTAssertNil(lastFolder)
        var filesOnly = WorkspaceLayout.default
        filesOnly.primary = .files
        vm.setLayout(filesOnly, projectID: projectID)
        vm.toggleFolderRoot(hub, projectID: projectID)
        await vm.newSessionOnPage()
        XCTAssertEqual(lastFolder, String(hub), "the off-screen app session is not the context")
    }

    /// Work on It on a target whose folder left the bench: home, and the
    /// start notice says why.
    func testWorkOnItOnARemovedFolderStartsInHomeAndSaysSo() async throws {
        let id = try await target(folder: old)
        await vm.workOn(targetID: id, targetText: "Export", projectID: projectID)
        XCTAssertNil(lastFolder)
        let homeName = try XCTUnwrap(try bench().home?.name)
        XCTAssertEqual(vm.startNotice[projectID], "Started in \(homeName): the target's folder old left the bench.")
    }

    /// F19: "In Its Own Worktree" in a folder's submenu is judged on that
    /// folder's git, not home's.
    func testUnavailableReasonReadsTheStartFoldersGit() throws {
        let hubFolder = try XCTUnwrap(try bench().folder(hub))
        vm.gitStatus[projectID] = WorkbenchGitStatus(branch: "main")
        vm.gitStatus[vm.folderRoot(hubFolder)] = WorkbenchGitStatus(git: false)
        XCTAssertNil(vm.worktreeUnavailableReason(projectID: projectID, folderID: home))
        XCTAssertNil(vm.worktreeUnavailableReason(projectID: projectID, folderID: nil))
        XCTAssertEqual(vm.worktreeUnavailableReason(projectID: projectID, folderID: hub),
                       "the folder is not in a git repository.")
    }

    func testNewSessionMenuFollowsTheContext() throws {
        let menu = try XCTUnwrap(vm.newSessionMenu(projectID: projectID))
        XCTAssertEqual(menu.contextFolderID, home)
        XCTAssertEqual(menu.otherFolders.map(\.title), ["in hub", "in site"])
        let homeName = try XCTUnwrap(try bench().home?.name)
        vm.toggleFolderRoot(site, projectID: projectID)
        let fromSite = try XCTUnwrap(vm.newSessionMenu(projectID: projectID))
        XCTAssertEqual(fromSite.contextFolderID, site, "no session on screen: the opened root")
        XCTAssertEqual(fromSite.otherFolders.map(\.title), ["in \(homeName)", "in hub"])
    }

    /// Dismiss shows only with a session host that lacks `prompt_state`
    /// (spec §5, D41); the hello's features say which.
    func testDismissOnlyWithAnOldHost() async throws {
        XCTAssertTrue(vm.promptNoticeOffersDismiss, "a host whose hello names no features: Dismiss")
        let current = SessionHostClient(socketPath: "/tmp/wt-test-2.sock", cliPath: { nil }, makeTransport: { _ in
            let transport = FakeSessionHostTransport()
            transport.helloFeatures = [SessionHostHello.promptStateFeature]
            return transport
        })
        let running = await current.ensureRunning()
        XCTAssertTrue(running)
        XCTAssertEqual(current.hostFeatures, ["prompt_state"])
        XCTAssertFalse(current.lacksPromptState)
        center.sessionHost = current
        XCTAssertFalse(vm.promptNoticeOffersDismiss, "the host reads the prompt itself: no Dismiss")
        center.sessionHost = nil
        XCTAssertFalse(vm.promptNoticeOffersDismiss, "no host known: no Dismiss")
        center.sessionHost = client
    }

    /// The prompt notice's Dismiss marks each flagged message through
    /// `workbench message dismiss --id`; the Desktop writes nothing itself.
    func testDismissCallsTheCLI() async throws {
        let projectID = projectID
        let (session, first, second) = try await pool.write { db in
            let session = try TerminalSessionQueries.create(
                db, .init(projectID: projectID, kind: .claude, title: "s", folderPath: "/tmp", claudeSessionID: "x")
            ).id
            var ids: [Int64] = []
            for cleared in [false, false, true] {
                try db.execute(sql: """
                    INSERT INTO session_messages (workbench_id, from_session_id, to_session_id, kind, text, state, reason,
                                                  prompt_cleared_at)
                    VALUES (?, NULL, ?, 'message', 'look at hub', 'delivered', 'typed_not_submitted', ?)
                    """, arguments: [projectID, session, cleared ? "2026-11-18T10:00:00Z" : nil])
                ids.append(db.lastInsertedRowID)
            }
            return (session, ids[0], ids[1])
        }
        let fake = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))
        let dismissing = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: fake), defaults: defaults)
        await dismissing.dismissPromptMessages(sessionID: session, projectID: projectID)
        XCTAssertEqual(fake.invocations, [
            ["workbench", "message", "dismiss", "--id", String(first), "--json"],
            ["workbench", "message", "dismiss", "--id", String(second), "--json"]
        ])
        let uncleared = try await pool.read { try SessionMessageQueries.waitingInPromptIDs($0, sessionID: session) }
        XCTAssertEqual(uncleared, [first, second], "no GRDB write: Go clears them")
        XCTAssertNil(dismissing.sessionErrors[projectID])
    }
}
