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

    func testAddArgsWithLabel() {
        let args = SlackAccountsViewModel.addArgs(label: "Personal")
        XCTAssertEqual(args, ["slack", "add", "--app-return", "--label", "Personal"])
    }

    func testAddArgsWithoutLabelOmitsFlag() {
        let args = SlackAccountsViewModel.addArgs(label: "")
        XCTAssertEqual(args, ["slack", "add", "--app-return"])
        XCTAssertFalse(args.contains("--label"))
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

    func testAddRestartsTheDaemonByDefault() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        await vm.addAccount(label: "")
        await vm.daemonRestartTask?.value
        XCTAssertNil(vm.error)
        XCTAssertEqual(daemon.restartCount, 1)
    }

    func testDeferredAddDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/true")
        await vm.addAccount(label: "", daemonPolicy: .deferred)
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

    func testFailedAddDoesNotRestartTheDaemon() async throws {
        let (vm, daemon, _) = try makeVM(cli: "/usr/bin/false")
        await vm.addAccount(label: "")
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.daemonRestartTask)
        XCTAssertEqual(daemon.restartCount, 0)
    }
}
