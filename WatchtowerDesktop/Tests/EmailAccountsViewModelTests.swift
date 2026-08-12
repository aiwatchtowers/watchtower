import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class EmailAccountsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    private func fetchAccount(_ pool: DatabasePool, id: Int64) throws -> EmailAccount {
        try pool.read { db in
            try XCTUnwrap(EmailAccount.fetchOne(db, sql: "SELECT * FROM email_accounts WHERE id = ?", arguments: [id]))
        }
    }

    // MARK: - refresh

    func testRefreshPopulatesAccountsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            try TestDatabase.insertEmailAccount(db, provider: "imap", emailAddress: "me@example.com")
        }
        let vm = EmailAccountsViewModel(dbPool: pool)
        XCTAssertTrue(vm.accounts.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.accounts.count, 1)
        XCTAssertEqual(vm.accounts[0].emailAddress, "me@example.com")
    }

    func testRefreshReplacesStaleAccounts() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertEmailAccount(db, provider: "imap", emailAddress: "me@example.com") }
        let vm = EmailAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.count, 1)

        try await pool.write { db in try db.execute(sql: "DELETE FROM email_accounts WHERE id = ?", arguments: [id]) }
        await vm.refreshAsync()

        XCTAssertTrue(vm.accounts.isEmpty)
    }

    // MARK: - remove(_:) provider-based dispatch

    func testRemoveArgsDispatchesToImapForPlainIMAPAccounts() throws {
        let pool = try makePool()
        let id = try pool.write { db in try TestDatabase.insertEmailAccount(db, provider: "imap", emailAddress: "me@example.com") }
        let account = try fetchAccount(pool, id: id)

        XCTAssertEqual(EmailAccountsViewModel.removeArgs(for: account), ["imap", "remove", String(id)])
    }

    func testRemoveArgsDispatchesToOutlookLogoutForOutlookAccounts() throws {
        let pool = try makePool()
        let id = try pool.write { db in try TestDatabase.insertEmailAccount(db, provider: "outlook", emailAddress: "me@outlook.com") }
        let account = try fetchAccount(pool, id: id)

        XCTAssertEqual(EmailAccountsViewModel.removeArgs(for: account), ["outlook", "logout", String(id)])
    }

    // MARK: - isRunning guard

    func testRemoveGuardsAgainstReentry() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertEmailAccount(db, provider: "imap", emailAddress: "me@example.com") }
        let account = try fetchAccount(pool, id: id)

        let vm = EmailAccountsViewModel(dbPool: pool)
        vm.isRunning = true

        await vm.remove(account)

        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isRunning, "the guard must not clear an in-flight flag it didn't set")

        // remove() must have returned before ever reaching the CLI dispatch —
        // the row is untouched.
        let stillThere = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM email_accounts WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(stillThere, 1)
    }

    func testAddImapAccountGuardsAgainstReentry() async throws {
        let pool = try makePool()
        let vm = EmailAccountsViewModel(dbPool: pool)
        vm.isRunning = true

        let success = await vm.addImapAccount(
            host: "imap.example.com", port: 993, username: "me@example.com",
            password: "secret", folder: "INBOX", security: "ssl", label: ""
        )

        XCTAssertFalse(success)
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isRunning, "the guard must not clear an in-flight flag it didn't set")

        let count = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM email_accounts") }
        XCTAssertEqual(count, 0, "no account should be created when the guard rejects the call")
    }
}
