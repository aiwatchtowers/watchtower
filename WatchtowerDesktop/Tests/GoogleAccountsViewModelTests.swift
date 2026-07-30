import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class GoogleAccountsViewModelTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    private func fetchAccount(_ pool: DatabasePool, id: Int64) throws -> GoogleAccount {
        try pool.read { db in
            try XCTUnwrap(GoogleAccount.fetchOne(db, sql: "SELECT * FROM google_accounts WHERE id = ?", arguments: [id]))
        }
    }

    // MARK: - refresh

    func testRefreshPopulatesAccountsFromDB() async throws {
        let pool = try makePool()
        try await pool.write { db in
            try TestDatabase.insertGoogleAccount(db, email: "me@gmail.com")
        }
        let vm = GoogleAccountsViewModel(dbPool: pool)
        XCTAssertTrue(vm.accounts.isEmpty)

        await vm.refreshAsync()

        XCTAssertEqual(vm.accounts.count, 1)
        XCTAssertEqual(vm.accounts[0].email, "me@gmail.com")
    }

    func testRefreshReplacesStaleAccounts() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertGoogleAccount(db, email: "me@gmail.com") }
        let vm = GoogleAccountsViewModel(dbPool: pool)
        await vm.refreshAsync()
        XCTAssertEqual(vm.accounts.count, 1)

        try await pool.write { db in try db.execute(sql: "DELETE FROM google_accounts WHERE id = ?", arguments: [id]) }
        await vm.refreshAsync()

        XCTAssertTrue(vm.accounts.isEmpty)
    }

    // MARK: - addArgs (pure)

    func testAddArgsBasicServicesNoLabelNoCustomClient() {
        let args = GoogleAccountsViewModel.addArgs(label: "", calendar: true, gmail: true, hasCustomClient: false, clientID: "")

        XCTAssertEqual(args.first, "google")
        XCTAssertEqual(args[1], "add")
        XCTAssertEqual(Set(args), Set(["google", "add", "--app-return", "--calendar", "--gmail"]))
    }

    func testAddArgsIncludesLabelWhenNonEmpty() {
        let args = GoogleAccountsViewModel.addArgs(label: "L", calendar: true, gmail: true, hasCustomClient: false, clientID: "")

        XCTAssertEqual(Set(args), Set(["google", "add", "--app-return", "--label", "L", "--calendar", "--gmail"]))
    }

    func testAddArgsOmitsServiceFlagsWhenNotSelected() {
        let args = GoogleAccountsViewModel.addArgs(label: "", calendar: false, gmail: true, hasCustomClient: false, clientID: "")

        XCTAssertFalse(args.contains("--calendar"))
        XCTAssertTrue(args.contains("--gmail"))
    }

    func testAddArgsIncludesClientFlagsWhenCustomClientSet() throws {
        let args = GoogleAccountsViewModel.addArgs(label: "", calendar: true, gmail: false, hasCustomClient: true, clientID: "cid")

        XCTAssertTrue(args.contains("--client-id"))
        let idIndex = try XCTUnwrap(args.firstIndex(of: "--client-id"))
        XCTAssertEqual(args[idIndex + 1], "cid")
        XCTAssertTrue(args.contains("--client-secret-stdin"))
    }

    func testAddArgsOmitsClientFlagsWhenNotCustom() {
        let args = GoogleAccountsViewModel.addArgs(label: "", calendar: true, gmail: false, hasCustomClient: false, clientID: "")

        XCTAssertFalse(args.contains("--client-id"))
        XCTAssertFalse(args.contains("--client-secret-stdin"))
    }

    // MARK: - loginArgs (pure)

    func testLoginArgsRerequestsCurrentlyGrantedServices() throws {
        let pool = try makePool()
        let id = try pool.write { db in
            try TestDatabase.insertGoogleAccount(db, calendarEnabled: true, gmailEnabled: false)
        }
        let account = try fetchAccount(pool, id: id)

        let args = GoogleAccountsViewModel.loginArgs(for: account)

        XCTAssertEqual(Set(args), Set(["google", "login", "--account", String(id), "--app-return", "--calendar"]))
    }

    func testLoginArgsWithBothServicesGranted() throws {
        let pool = try makePool()
        let id = try pool.write { db in
            try TestDatabase.insertGoogleAccount(db, calendarEnabled: true, gmailEnabled: true)
        }
        let account = try fetchAccount(pool, id: id)

        let args = GoogleAccountsViewModel.loginArgs(for: account)

        XCTAssertTrue(args.contains("--calendar"))
        XCTAssertTrue(args.contains("--gmail"))
    }

    // MARK: - removeArgs (pure)

    func testRemoveArgsBuildsGoogleRemove() throws {
        let pool = try makePool()
        let id = try pool.write { db in try TestDatabase.insertGoogleAccount(db, email: "me@gmail.com") }
        let account = try fetchAccount(pool, id: id)

        XCTAssertEqual(GoogleAccountsViewModel.removeArgs(for: account), ["google", "remove", String(id)])
    }

    // MARK: - isConnecting guard

    func testRemoveGuardsAgainstReentry() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertGoogleAccount(db, email: "me@gmail.com") }
        let account = try fetchAccount(pool, id: id)

        let vm = GoogleAccountsViewModel(dbPool: pool)
        vm.isConnecting = true

        await vm.remove(account)

        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isConnecting, "the guard must not clear an in-flight flag it didn't set")

        // remove() must have returned before ever reaching the CLI dispatch —
        // the row is untouched.
        let stillThere = try await pool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM google_accounts WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(stillThere, 1)
    }

    func testAddAccountGuardsAgainstReentry() throws {
        let pool = try makePool()
        let vm = GoogleAccountsViewModel(dbPool: pool)
        vm.isConnecting = true

        vm.addAccount(label: "", calendar: true, gmail: false, clientID: "", clientSecret: "")

        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isConnecting, "the guard must not clear an in-flight flag it didn't set")
    }

    func testReloginGuardsAgainstReentry() throws {
        let pool = try makePool()
        let id = try pool.write { db in try TestDatabase.insertGoogleAccount(db, email: "me@gmail.com") }
        let account = try fetchAccount(pool, id: id)
        let vm = GoogleAccountsViewModel(dbPool: pool)
        vm.isConnecting = true

        vm.relogin(account)

        XCTAssertEqual(vm.error, "Another connection is already in progress.")
        XCTAssertTrue(vm.isConnecting, "the guard must not clear an in-flight flag it didn't set")
    }

    // MARK: - cancelConnect

    func testCancelConnectClearsIsConnectingWithNoInFlightProcess() throws {
        let pool = try makePool()
        let vm = GoogleAccountsViewModel(dbPool: pool)
        vm.isConnecting = true

        vm.cancelConnect()

        XCTAssertFalse(vm.isConnecting)
    }
}
