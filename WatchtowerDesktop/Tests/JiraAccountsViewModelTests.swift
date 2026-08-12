import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

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
        XCTAssertEqual(args, ["jira", "add", "--label", "Client"])
    }

    func testAddArgsWithoutLabelOmitsFlag() {
        let args = JiraAccountsViewModel.addArgs(label: "")
        XCTAssertEqual(args, ["jira", "add"])
        XCTAssertFalse(args.contains("--label"))
    }

    // A grant reaching several Atlassian sites can only be resolved by naming
    // one: the CLI's picker reads stdin, which the spawned Process never wires.
    func testAddArgsWithSite() {
        let args = JiraAccountsViewModel.addArgs(label: "Client", site: "acme.atlassian.net")
        XCTAssertEqual(args, ["jira", "add", "--label", "Client", "--site", "acme.atlassian.net"])
    }

    func testAddArgsWithSiteOnly() {
        let args = JiraAccountsViewModel.addArgs(label: "", site: "acme.atlassian.net")
        XCTAssertEqual(args, ["jira", "add", "--site", "acme.atlassian.net"])
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
            ["jira", "login", "--account", "7"]
        )
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
