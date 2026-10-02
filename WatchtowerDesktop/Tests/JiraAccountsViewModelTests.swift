import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class JiraAccountsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    // MARK: - refresh

    func testRefreshPopulatesAccountsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            _ = try TestDatabase.insertJiraAccount(db, siteName: "Acme")
        }
        let vm = JiraAccountsViewModel(dbPool: pool)
        XCTAssertTrue(vm.accounts.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.accounts.count, 1)
        XCTAssertEqual(vm.accounts[0].siteName, "Acme")
    }

    /// AppState re-resolves the owner (OWNER-01) through this hook: every
    /// add/remove/enable/re-login ends in a refresh, so the callback must fire
    /// after each successful reload.
    func testRefreshNotifiesAccountsChanged() async throws {
        let pool = try makePool()
        let vm = JiraAccountsViewModel(dbPool: pool)
        var calls = 0
        vm.onAccountsChanged = { calls += 1 }

        await vm.refreshAsync()
        await vm.refreshAsync()

        XCTAssertEqual(calls, 2)
    }

    func testRefreshReplacesStaleAccounts() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertJiraAccount(db, siteName: "Acme") }
        let vm = JiraAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.count, 1)

        try await pool.write { db in try db.execute(sql: "DELETE FROM jira_accounts WHERE id = ?", arguments: [id]) }
        await vm.refreshAsync()

        XCTAssertTrue(vm.accounts.isEmpty)
    }

    // MARK: - addArgs (pure)

    func testAddArgsWithLabel() {
        let args = JiraAccountsViewModel.addArgs(label: "Client")
        XCTAssertEqual(args, ["jira", "add", "--app-return", "--label", "Client"])
    }

    func testAddArgsWithoutLabelOmitsFlag() {
        let args = JiraAccountsViewModel.addArgs(label: "")
        XCTAssertEqual(args, ["jira", "add", "--app-return"])
        XCTAssertFalse(args.contains("--label"))
    }

    // A grant reaching several Atlassian sites can only be resolved by naming
    // one: the CLI's picker reads stdin, which the spawned Process never wires.
    func testAddArgsWithSite() {
        let args = JiraAccountsViewModel.addArgs(label: "Client", site: "acme.atlassian.net")
        XCTAssertEqual(args, ["jira", "add", "--app-return", "--label", "Client", "--site", "acme.atlassian.net"])
    }

    func testAddArgsWithSiteOnly() {
        let args = JiraAccountsViewModel.addArgs(label: "", site: "acme.atlassian.net")
        XCTAssertEqual(args, ["jira", "add", "--app-return", "--site", "acme.atlassian.net"])
    }

    func testAddArgsWithoutSiteOmitsFlag() {
        let args = JiraAccountsViewModel.addArgs(label: "Client")
        XCTAssertFalse(args.contains("--site"))
    }

    // MARK: - removeArgs (pure)

    func testRemoveArgs() {
        let account = JiraAccount(row: Row(["id": 3]))
        XCTAssertEqual(JiraAccountsViewModel.removeArgs(for: account), ["jira", "remove", "3"])
    }

    // MARK: - loginArgs (pure)

    func testLoginArgs() {
        let account = JiraAccount(row: Row(["id": 7]))
        XCTAssertEqual(
            JiraAccountsViewModel.loginArgs(for: account),
            ["jira", "login", "--account", "7", "--app-return"]
        )
    }

    /// "Grant Confluence access" rides the same login flow plus
    /// `--with-confluence`; the default Re-login must never ask for the
    /// Confluence scopes (they are opt-in on the CLI side).
    func testLoginArgsWithConfluence() {
        XCTAssertEqual(
            JiraAccountsViewModel.loginArgs(accountID: 3, withConfluence: true),
            ["jira", "login", "--account", "3", "--app-return", "--with-confluence"]
        )
        XCTAssertFalse(JiraAccountsViewModel.loginArgs(accountID: 3).contains("--with-confluence"))
    }

    /// "Allow editing" asks for the Confluence write scopes via
    /// `--with-confluence-write` (which implies read on the CLI side); no
    /// other re-login ever adds it.
    func testLoginArgsWithConfluenceWrite() {
        XCTAssertEqual(
            JiraAccountsViewModel.loginArgs(accountID: 3, withConfluenceWrite: true),
            ["jira", "login", "--account", "3", "--app-return", "--with-confluence-write"]
        )
        XCTAssertFalse(JiraAccountsViewModel.loginArgs(accountID: 3, withConfluence: true).contains("--with-confluence-write"))
        XCTAssertFalse(JiraAccountsViewModel.loginArgs(accountID: 3).contains("--with-confluence-write"))
    }

    // MARK: - setEnabledArgs (pure)

    func testSetEnabledArgsEnable() {
        let account = JiraAccount(row: Row(["id": 2]))
        XCTAssertEqual(JiraAccountsViewModel.setEnabledArgs(for: account, enabled: true), ["jira", "enable", "2"])
    }

    func testSetEnabledArgsDisable() {
        let account = JiraAccount(row: Row(["id": 2]))
        XCTAssertEqual(JiraAccountsViewModel.setEnabledArgs(for: account, enabled: false), ["jira", "disable", "2"])
    }
}

// MARK: - Daemon restart policy
//
// `/usr/bin/true` / `/usr/bin/false` stand in for the CLI: the VM's own
// success/failure branch runs for real, only the daemon restart is faked.

extension JiraAccountsViewModelTests {
    private func makeVM(cli: String) throws -> (JiraAccountsViewModel, FakeDaemonRestarter, DatabasePool) {
        let pool = try makePool()
        let daemon = FakeDaemonRestarter()
        return (JiraAccountsViewModel(dbPool: pool, daemon: daemon) { cli }, daemon, pool)
    }

    private func insertAccount(_ pool: DatabasePool) async throws -> JiraAccount {
        try await pool.write { db in _ = try TestDatabase.insertJiraAccount(db) }
        let rows = try await pool.read { db in try JiraAccountQueries.fetchAll(db) }
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
