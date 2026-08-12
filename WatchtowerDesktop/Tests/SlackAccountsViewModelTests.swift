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
