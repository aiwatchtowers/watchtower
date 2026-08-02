import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class CalendarAccountsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    private func fetchAccount(_ pool: DatabasePool, id: Int64) throws -> CalendarAccount {
        try pool.read { db in
            try XCTUnwrap(
                CalendarAccount.fetchOne(db, sql: "SELECT * FROM calendar_accounts WHERE id = ?", arguments: [id])
            )
        }
    }

    // MARK: - refresh

    func testRefreshPopulatesAccountsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            try TestDatabase.insertCalendarAccount(db, provider: "caldav", username: "me@icloud.com")
        }
        let vm = CalendarAccountsViewModel(dbPool: pool)
        XCTAssertTrue(vm.accounts.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.accounts.count, 1)
        XCTAssertEqual(vm.accounts[0].username, "me@icloud.com")
    }

    func testRefreshReplacesStaleAccounts() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in
            try TestDatabase.insertCalendarAccount(db, provider: "caldav", username: "me@icloud.com")
        }
        let vm = CalendarAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.count, 1)

        try await pool.write { db in
            try db.execute(sql: "DELETE FROM calendar_accounts WHERE id = ?", arguments: [id])
        }
        await vm.refreshAsync()

        XCTAssertTrue(vm.accounts.isEmpty)
    }

    // MARK: - remove(_:) args

    /// Unlike email (imap remove vs outlook logout), BOTH calendar providers
    /// remove via the same `caldav remove <id>` CLI command.
    func testRemoveArgsSameCommandForCalDAVAndICS() throws {
        let pool = try makePool()
        let caldavID = try pool.write { db in
            try TestDatabase.insertCalendarAccount(db, provider: "caldav", username: "me@icloud.com")
        }
        let icsID = try pool.write { db in
            try TestDatabase.insertCalendarAccount(db, provider: "ics", username: "", url: "")
        }
        let caldav = try fetchAccount(pool, id: caldavID)
        let ics = try fetchAccount(pool, id: icsID)

        XCTAssertEqual(CalendarAccountsViewModel.removeArgs(for: caldav), ["caldav", "remove", String(caldavID)])
        XCTAssertEqual(CalendarAccountsViewModel.removeArgs(for: ics), ["caldav", "remove", String(icsID)])
    }

    // MARK: - isRunning guard

    func testRemoveGuardsAgainstReentry() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in
            try TestDatabase.insertCalendarAccount(db, provider: "caldav", username: "me@icloud.com")
        }
        let account = try fetchAccount(pool, id: id)

        let vm = CalendarAccountsViewModel(dbPool: pool)
        vm.isRunning = true

        await vm.remove(account)

        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isRunning, "the guard must not clear an in-flight flag it didn't set")

        // remove() must have returned before ever reaching the CLI dispatch —
        // the row is untouched.
        let stillThere = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendar_accounts WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(stillThere, 1)
    }

    func testAddCalDAVGuardsAgainstReentry() async throws {
        let pool = try makePool()
        let vm = CalendarAccountsViewModel(dbPool: pool)
        vm.isRunning = true

        let success = await vm.addCalDAV(
            url: "https://caldav.icloud.com", username: "me@icloud.com",
            password: "secret", label: ""
        )

        XCTAssertFalse(success)
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isRunning, "the guard must not clear an in-flight flag it didn't set")

        let count = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendar_accounts") }
        XCTAssertEqual(count, 0, "no account should be created when the guard rejects the call")
    }

    func testAddICSGuardsAgainstReentry() async throws {
        let pool = try makePool()
        let vm = CalendarAccountsViewModel(dbPool: pool)
        vm.isRunning = true

        let success = await vm.addICS(feedURL: "https://calendar.google.com/calendar/ical/secret.ics", label: "")

        XCTAssertFalse(success)
        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isRunning, "the guard must not clear an in-flight flag it didn't set")

        let count = try await pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM calendar_accounts") }
        XCTAssertEqual(count, 0, "no account should be created when the guard rejects the call")
    }
}
