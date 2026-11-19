import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class SlackAccountsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    // MARK: - refresh

    func testRefreshPopulatesAccountsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme")
        }
        let vm = SlackAccountsViewModel(dbPool: pool)
        XCTAssertTrue(vm.accounts.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.accounts.count, 1)
        XCTAssertEqual(vm.accounts[0].teamName, "Acme")
    }

    /// AppState re-resolves the owner (OWNER-01) through this hook: every
    /// add/remove/enable/re-login ends in a refresh, so the callback must fire
    /// after each successful reload.
    func testRefreshNotifiesAccountsChanged() async throws {
        let pool = try makePool()
        let vm = SlackAccountsViewModel(dbPool: pool)
        var calls = 0
        vm.onAccountsChanged = { calls += 1 }

        await vm.refreshAsync()
        await vm.refreshAsync()

        XCTAssertEqual(calls, 2)
    }

    func testRefreshReplacesStaleAccounts() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertSlackAccount(db, teamName: "Acme") }
        let vm = SlackAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.count, 1)

        try await pool.write { db in try db.execute(sql: "DELETE FROM slack_accounts WHERE id = ?", arguments: [id]) }
        await vm.refreshAsync()

        XCTAssertTrue(vm.accounts.isEmpty)
    }

    // MARK: - addArgs (pure)

    // The connect never names the workspace: the CLI labels it after its team.
    func testAddArgsCarryNoLabel() {
        XCTAssertEqual(SlackAccountsViewModel.addArgs, ["slack", "add", "--app-return"])
    }

    // MARK: - removeArgs (pure)

    func testRemoveArgs() {
        let account = SlackAccount(row: Row(["id": 3]))
        XCTAssertEqual(SlackAccountsViewModel.removeArgs(for: account), ["slack", "remove", "3"])
    }

    // MARK: - loginArgs (pure)

    func testLoginArgs() {
        let account = SlackAccount(row: Row(["id": 7]))
        XCTAssertEqual(
            SlackAccountsViewModel.loginArgs(for: account),
            ["slack", "login", "--account", "7", "--app-return"]
        )
    }

    // MARK: - setEnabledArgs (pure)

    func testSetEnabledArgsEnable() {
        let account = SlackAccount(row: Row(["id": 2]))
        XCTAssertEqual(SlackAccountsViewModel.setEnabledArgs(for: account, enabled: true), ["slack", "enable", "2"])
    }

    func testSetEnabledArgsDisable() {
        let account = SlackAccount(row: Row(["id": 2]))
        XCTAssertEqual(SlackAccountsViewModel.setEnabledArgs(for: account, enabled: false), ["slack", "disable", "2"])
    }
}

// MARK: - Daemon restart policy
//
// `/usr/bin/true` / `/usr/bin/false` stand in for the CLI: the VM's own
// success/failure branch runs for real, only the daemon restart is faked.

extension SlackAccountsViewModelTests {
    private func makeVM(cli: String) throws -> (SlackAccountsViewModel, FakeDaemonRestarter, DatabasePool) {
        let pool = try makePool()
        let daemon = FakeDaemonRestarter()
        return (SlackAccountsViewModel(dbPool: pool, daemon: daemon) { cli }, daemon, pool)
    }

    private func insertAccount(_ pool: DatabasePool) async throws -> SlackAccount {
        try await pool.write { db in _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme") }
        let rows = try await pool.read { db in try SlackAccountQueries.fetchAll(db) }
        return try XCTUnwrap(rows.first)
    }

    /// Board #592: a Cancel while the login environment resolves (the flow
    /// already shown as running) drops the launch: no CLI run, no restart.
    func testCancelDuringTheEnvironmentAwaitDropsTheLaunch() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        let gate = AsyncGate()
        vm.loginEnvironment = { await gate.wait(); return [:] }
        let flow = Task { await vm.addAccount() }
        let shown = await waitForCondition { vm.isConnecting }
        XCTAssertTrue(shown, "spinner and Cancel before the environment resolves")
        vm.cancelConnect()
        gate.release()
        await flow.value
        XCTAssertFalse(vm.isConnecting)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0, "the dropped launch never ran the CLI")
    }

    func testAddRestartsTheDaemonByDefault() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        await vm.addAccount()
        await vm.daemonRestartTask?.value
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testDeferredAddDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        await vm.addAccount(daemonPolicy: .deferred)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testRemoveRestartsTheDaemonByDefault() async throws {
        let (vm, daemon, pool) = try makeVM(cli: "/usr/bin/true")
        let account = try await insertAccount(pool)
        await vm.remove(account)
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testDeferredRemoveDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, pool) = try makeVM(cli: "/usr/bin/true")
        let account = try await insertAccount(pool)
        await vm.remove(account, daemonPolicy: .deferred)
        XCTAssertNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    // Rename touches only the label: it reloads the list and never restarts
    // the daemon; a refused rename leaves the CLI's message on screen.
    func testRenameReloadsWithoutRestartingTheDaemon() async throws {
        let (vm, daemon, pool) = try makeVM(cli: "/usr/bin/true")
        let account = try await insertAccount(pool)
        var reloads = 0
        vm.onAccountsChanged = { reloads += 1 }
        await vm.rename(accountID: account.id, to: "Work")
        XCTAssertNil(vm.error)
        XCTAssertEqual(reloads, 1)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testFailedRenameShowsTheErrorAndDoesNotReload() async throws {
        let (vm, _, pool) = try makeVM(cli: "/usr/bin/false")
        let account = try await insertAccount(pool)
        var reloads = 0
        vm.onAccountsChanged = { reloads += 1 }
        await vm.rename(accountID: account.id, to: "Work")
        XCTAssertEqual(vm.error, "Rename failed (exit 1)")
        XCTAssertEqual(reloads, 0)
    }

    /// #1769: `slack remove` exits 0 when Slack did not confirm the revoke and
    /// prints the warning; the VM shows it as a notice, not an error.
    func testUnconfirmedRevokeBecomesANotice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\necho '\(SlackRevokeNotice.cliWarning)'\necho 'Removed account 1. Its synced data was kept.'\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let pool = try makePool()
        var cli = stub.path
        let vm = SlackAccountsViewModel(dbPool: pool, daemon: FakeDaemonRestarter()) { cli }
        let account = try await insertAccount(pool)
        await vm.remove(account, daemonPolicy: .deferred)
        XCTAssertNil(vm.error)
        XCTAssertEqual(vm.revokeNotice, SlackRevokeNotice.cliWarning)

        cli = "/usr/bin/true"
        await vm.remove(account, daemonPolicy: .deferred)
        XCTAssertNil(vm.revokeNotice, "a confirmed remove clears an earlier notice")
    }

    func testFailedAddDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/false")
        await vm.addAccount()
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }
}

// MARK: - Re-login routing (plan B A7)

extension SlackAccountsViewModelTests {
    /// A stand-in CLI that answers `slack accounts --json` with `doc`.
    private func accountsCLI(_ doc: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\ncat <<'JSON'\n\(doc)\nJSON\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    private func connectFlow() async -> (SlackConnectFlowModel, FakeCLILineSession) {
        let fake = FakeCLILineStream()
        let host = SlackConnectListenerHost(streamer: fake)
        let flow = SlackConnectFlowModel(host: host)
        host.ensureRunning()
        return (flow, await fake.session(number: 1))
    }

    /// A workspace-app account re-binds through the running listener, never
    /// `slack login` (which would bind 18551, held by that listener).
    func testReloginOfWorkspaceAppStartsTheConnectFlow() async throws {
        let cli = try accountsCLI(#"{"builtin_app":false,"accounts":[{"id":1,"team_id":"T0ACME","client_id":"1111.2222","#
            + #""shared_app":false,"relogin":"connect"}]}"#)
        let (vm, daemon, pool) = try makeVM(cli: cli)
        let (flow, child) = await connectFlow()
        vm.connectFlow = flow
        let account = try await insertAccount(pool)

        let route = await vm.relogin(account)
        XCTAssertEqual(route, .flow(SlackConnectTarget(teamID: "T0ACME", clientID: "1111.2222", accountID: Int64(account.id))))
        XCTAssertNil(vm.error)
        XCTAssertEqual(child.writtenLines,
                       [#"{"account_id":\#(account.id),"client_id":"1111.2222","cmd":"start","team_id":"T0ACME"}"#])
        XCTAssertFalse(vm.isConnecting, "no `slack login` child")
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testReloginOnTheSharedAppOpensTheConnectSection() async throws {
        let cli = try accountsCLI(#"{"builtin_app":false,"accounts":[{"id":1,"team_id":"T0ACME","client_id":"9.9","#
            + #""shared_app":true,"relogin":"move"}]}"#)
        let (vm, _, pool) = try makeVM(cli: cli)
        let (flow, child) = await connectFlow()
        vm.connectFlow = flow
        let account = try await insertAccount(pool)

        let route = await vm.relogin(account)
        XCTAssertEqual(route, .connectSection)
        XCTAssertEqual(child.writtenLines, [])
        XCTAssertEqual(flow.connectSectionRequest, 1)
    }

    func testReloginWithUnreadableAccountsStartsNothing() async throws {
        let (vm, daemon, pool) = try makeVM(cli: "/usr/bin/false")
        let (flow, child) = await connectFlow()
        vm.connectFlow = flow
        let account = try await insertAccount(pool)

        let route = await vm.relogin(account)
        XCTAssertNil(route)
        XCTAssertEqual(vm.error, "Could not read the Slack accounts: exit 1")
        XCTAssertEqual(child.writtenLines, [])
        XCTAssertEqual(daemon.restartCount, 0)
    }

    func testConnectFlowWriteReloadsAndRestarts() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        vm.connectFlowWroteAccount(daemonPolicy: .restart)
        await vm.daemonRestartTask?.value
        XCTAssertEqual(daemon.restartCount, 1)
        vm.connectFlowWroteAccount(daemonPolicy: .deferred)
        XCTAssertEqual(daemon.restartCount, 1, "onboarding defers the restart")
    }

    /// Fix round 1: the built-in route waits for a running connect flow too.
    func testBuiltinReloginWhileTheFlowRunsIsRefused() async throws {
        let cli = try accountsCLI(#"{"builtin_app":true,"accounts":[{"id":1,"team_id":"T0ACME","client_id":"5.6","#
            + #""shared_app":false,"relogin":"builtin"}]}"#)
        let (vm, daemon, pool) = try makeVM(cli: cli)
        let (flow, child) = await connectFlow()
        vm.connectFlow = flow
        XCTAssertTrue(flow.start(SlackConnectTarget(teamID: "T0OTHER", clientID: "1.2")))
        let account = try await insertAccount(pool)

        let route = await vm.relogin(account)
        XCTAssertNil(route)
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertEqual(child.writtenLines.count, 1, "only the running flow's start")
        XCTAssertEqual(daemon.restartCount, 0)
    }

    /// A refused hand-off (a flow already runs) is not a route taken.
    func testRefusedHandOffReturnsNil() async throws {
        let cli = try accountsCLI(#"{"builtin_app":false,"accounts":[{"id":1,"team_id":"T0ACME","client_id":"1.2","#
            + #""shared_app":false,"relogin":"connect"}]}"#)
        let (vm, _, pool) = try makeVM(cli: cli)
        let (flow, _) = await connectFlow()
        vm.connectFlow = flow
        XCTAssertTrue(flow.start(SlackConnectTarget(teamID: "T0OTHER", clientID: "3.4")))
        let account = try await insertAccount(pool)

        let route = await vm.relogin(account)
        XCTAssertNil(route)
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertFalse(vm.isConnecting, "the route read ends its busy mark")
    }

    /// Fix round 2: a hand-off clears an earlier failure's line.
    func testHandOffClearsAnEarlierError() async throws {
        let cli = try accountsCLI(#"{"builtin_app":false,"accounts":[{"id":1,"team_id":"T0ACME","client_id":"1.2","#
            + #""shared_app":false,"relogin":"connect"}]}"#)
        let (vm, _, pool) = try makeVM(cli: cli)
        let (flow, _) = await connectFlow()
        vm.connectFlow = flow
        vm.error = "Re-login failed (exit 1)"
        let account = try await insertAccount(pool)
        let route = await vm.relogin(account)
        XCTAssertEqual(route, .flow(SlackConnectTarget(teamID: "T0ACME", clientID: "1.2", accountID: Int64(account.id))))
        XCTAssertNil(vm.error)
    }
}

// MARK: - Flags from `slack accounts --json` (plan B Task 15)

extension SlackAccountsViewModelTests {
    private func flagsCLI(_ doc: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("watchtower")
        try "#!/bin/sh\ncat <<'JSON'\n\(doc)\nJSON\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub.path
    }

    private static let sharedDoc = #"{"builtin_app":false,"accounts":[{"id":1,"team_id":"T0ACME","client_id":"9.9","#
        + #""shared_app":true,"relogin":"move"},{"id":2,"team_id":"T0BETA","client_id":"1.2","#
        + #""shared_app":false,"relogin":"connect"}]}"#

    /// Each refresh merges Go's flags by account id.
    func testRefreshMergesFlagsByID() async throws {
        let cli = try flagsCLI(Self.sharedDoc)
        let vm = SlackAccountsViewModel(dbPool: try makePool(), daemon: FakeDaemonRestarter(), cliPath: { cli },
                                        readsAccountFlags: true)
        XCTAssertTrue(vm.builtinApp, "unknown counts as the build's own app")
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedAppAccountIDs, [1])
        XCTAssertFalse(vm.builtinApp)
        XCTAssertEqual(vm.relogin(of: 1), "move")
        XCTAssertEqual(vm.relogin(of: 2), "connect")
        XCTAssertNil(vm.relogin(of: 3))
    }

    /// A failed read keeps the last flags; with none yet, nothing is shared
    /// (no banner) and `builtin_app` stays unknown.
    func testFlagsReadFailureKeepsLast() async throws {
        let good = try flagsCLI(Self.sharedDoc)
        var cli = "/usr/bin/false"
        let vm = SlackAccountsViewModel(dbPool: try makePool(), daemon: FakeDaemonRestarter(), cliPath: { cli },
                                        readsAccountFlags: true)
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedAppAccountIDs, [], "no banner on a first failed read")
        XCTAssertTrue(vm.builtinApp, "unknown keeps Add Slack Workspace")
        XCTAssertNil(vm.readError, "the flags are not the account read")

        cli = good
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedAppAccountIDs, [1])

        cli = "/usr/bin/false"
        await vm.refreshAsync()
        XCTAssertEqual(vm.sharedAppAccountIDs, [1], "a failed read keeps the last flags")
        XCTAssertFalse(vm.builtinApp)
        cli = "/usr/bin/true" // exit 0, no JSON
        await vm.refreshAsync()
        XCTAssertEqual(vm.relogin(of: 1), "move")
        XCTAssertNil(vm.error)
    }

    /// Off by default: a test VM never runs the CLI for flags.
    func testFlagsNotReadByDefault() async throws {
        let cli = try flagsCLI(Self.sharedDoc)
        let vm = SlackAccountsViewModel(dbPool: try makePool(), daemon: FakeDaemonRestarter()) { cli }
        await vm.refreshAsync()
        XCTAssertNil(vm.accountFlags)
    }

    /// The Re-login route's read updates the row's flags too.
    func testRouteReadUpdatesFlags() async throws {
        let cli = try flagsCLI(Self.sharedDoc)
        let vm = SlackAccountsViewModel(dbPool: try makePool(), daemon: FakeDaemonRestarter()) { cli }
        _ = await vm.reloginRoute(accountID: 1)
        XCTAssertEqual(vm.relogin(of: 1), "move")
        XCTAssertEqual(vm.sharedAppAccountIDs, [1])
    }

    /// The shared-app line's age: each account's newest channel sync.
    func testLastSyncPerAccount() async throws {
        let pool = try makePool()
        try await pool.write { db in
            for (channel, stamp) in [("1:C1", "2026-11-18T10:00:00Z"), ("1:C2", "2026-11-18T11:00:00Z"),
                                     ("2:C1", ""), ("C9", "2026-11-18T12:00:00Z")] {
                try db.execute(sql: "INSERT INTO sync_state (channel_id, last_sync_at) VALUES (?, ?)",
                               arguments: [channel, stamp])
            }
        }
        let vm = SlackAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.lastSyncs.keys.sorted(), [1])
        XCTAssertEqual(vm.lastSyncs[1], TimeFormatting.parseISO("2026-11-18T11:00:00Z"))
    }
}
