import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

/// Covers `GoogleConnectFlow.connectArgs` — the pure dispatch (I2/I3) that
/// decides `google add` (no accounts yet) vs `google login --account <id>`
/// (widen the oldest existing account) without shelling out to a real
/// process or touching a DB, mirroring `GoogleAccountsViewModel.addArgs`/
/// `loginArgs`'s existing test style.
@MainActor
final class GoogleConnectFlowTests: XCTestCase {

    private func makeAccount(id: Int64, email: String) throws -> GoogleAccount {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        let pool = manager.dbPool
        try pool.write { db in
            try db.execute(
                sql: "INSERT INTO google_accounts (id, email) VALUES (?, ?)",
                arguments: [id, email]
            )
        }
        let accounts = try pool.read { db in try GoogleAccountQueries.fetchAll(db) }
        return try XCTUnwrap(accounts.first { $0.id == Int(id) })
    }

    func testConnectArgsAddsWhenNoAccountsExist() {
        let args = GoogleConnectFlow.connectArgs(accounts: [], wantCalendar: true, wantGmail: true)
        XCTAssertEqual(args, ["google", "add", "--app-return", "--calendar", "--gmail"])
    }

    func testConnectArgsLogsInToOldestAccountWhenAccountsExist() throws {
        // Removing account #1 and reconnecting must widen account #2 (the
        // oldest SURVIVING row), never spawn a third account — this is the
        // bug I3 fixes: the old file-stat heuristic couldn't tell "account #1
        // gone, account #2 still connected" from "nothing connected at all".
        let second = try makeAccount(id: 2, email: "second@gmail.com")

        let args = GoogleConnectFlow.connectArgs(accounts: [second], wantCalendar: true, wantGmail: false)

        XCTAssertEqual(args, ["google", "login", "--account", "2", "--app-return", "--calendar"])
    }

    func testConnectArgsOmitsFlagsForServicesNotWanted() throws {
        let account = try makeAccount(id: 1, email: "me@gmail.com")

        let args = GoogleConnectFlow.connectArgs(accounts: [account], wantCalendar: false, wantGmail: false)

        XCTAssertEqual(args, ["google", "login", "--account", "1", "--app-return"])
    }

    func testConnectArgsUsesFirstAccountWhenMultipleExist() throws {
        // accounts[0] must win — fetchAll orders by id ASC, so this is the
        // oldest surviving account, matching the Go-side alias semantics.
        let (manager, _) = try TestDatabase.createDatabaseManager()
        let pool = manager.dbPool
        try pool.write { db in
            try db.execute(sql: "INSERT INTO google_accounts (id, email) VALUES (5, 'oldest@gmail.com')")
            try db.execute(sql: "INSERT INTO google_accounts (id, email) VALUES (9, 'newest@gmail.com')")
        }
        let accounts = try pool.read { db in try GoogleAccountQueries.fetchAll(db) }

        let args = GoogleConnectFlow.connectArgs(accounts: accounts, wantCalendar: true, wantGmail: true)

        XCTAssertEqual(args, ["google", "login", "--account", "5", "--app-return", "--calendar", "--gmail"])
    }

    // MARK: - cancel() state machine (N1)
    //
    // connect()'s actual race (cancel() landing in the window between
    // isRunning=true and loginProcess being assigned, while an in-flight
    // Task is mid-DB-read) isn't unit-testable here: it needs a real CLI
    // process launch (`Constants.findCLIPath()`, environment-dependent —
    // see GoogleAccountsViewModelTests' equivalent reentrancy tests, which
    // for the same reason only ever exercise the "already busy" guard, never
    // the path that reaches the CLI) and real async timing to land inside a
    // one-await-point window. What IS testable without either: cancel()'s
    // safety on the "nothing in flight" edge, which exercises the new
    // `connectTask?.cancel()` line's nil-optional path.
    func testCancelWithNoActiveConnectIsSafeNoop() {
        let flow = GoogleConnectFlow()
        flow.cancel()
        XCTAssertFalse(flow.isRunning)
        // Calling it twice must also be safe (connectTask already nil).
        flow.cancel()
        XCTAssertFalse(flow.isRunning)
    }
}
