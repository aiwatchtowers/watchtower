import XCTest
import GRDB
@testable import WatchtowerDesktop

final class GoogleAccountQueriesTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    func testFetchAllRoundTripsSeededRowsOrderedByID() throws {
        let pool = try makePool()
        let secondID = try pool.write { db -> Int64 in
            _ = try TestDatabase.insertGoogleAccount(db, email: "a@gmail.com", label: "Work")
            return try TestDatabase.insertGoogleAccount(db, email: "b@gmail.com", label: "Personal")
        }

        let accounts = try pool.read { db in try GoogleAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 2)
        // Ordered by id ASC — the earlier-inserted row comes first.
        XCTAssertEqual(accounts[0].email, "a@gmail.com")
        XCTAssertEqual(accounts[0].label, "Work")
        XCTAssertEqual(accounts[1].email, "b@gmail.com")
        XCTAssertEqual(accounts[1].label, "Personal")
        XCTAssertEqual(accounts[1].id, Int(secondID))
    }

    func testFetchAllEmptyWhenNoAccounts() throws {
        let pool = try makePool()
        let accounts = try pool.read { db in try GoogleAccountQueries.fetchAll(db) }
        XCTAssertTrue(accounts.isEmpty)
    }

    func testFetchAllDecodesAllFields() throws {
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertGoogleAccount(
                db, email: "me@gmail.com", label: "Personal", clientID: "custom-client",
                calendarEnabled: true, gmailEnabled: false, status: "error", error: "token revoked"
            )
        }

        let accounts = try pool.read { db in try GoogleAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 1)
        let a = accounts[0]
        XCTAssertEqual(a.email, "me@gmail.com")
        XCTAssertEqual(a.label, "Personal")
        XCTAssertEqual(a.clientID, "custom-client")
        XCTAssertTrue(a.calendarEnabled)
        XCTAssertFalse(a.gmailEnabled)
        XCTAssertEqual(a.status, "error")
        XCTAssertEqual(a.error, "token revoked")
        XCTAssertFalse(a.isOK)
        XCTAssertEqual(a.displayName, "Personal")
    }

    func testDisplayNameFallsBackToEmailThenID() throws {
        let pool = try makePool()
        let idWithEmail = try pool.write { db in
            try TestDatabase.insertGoogleAccount(db, email: "me@gmail.com", label: "")
        }
        let idBare = try pool.write { db in
            try TestDatabase.insertGoogleAccount(db, email: "", label: "")
        }

        let accounts = try pool.read { db in try GoogleAccountQueries.fetchAll(db) }
        let withEmail = try XCTUnwrap(accounts.first { $0.id == Int(idWithEmail) })
        let bare = try XCTUnwrap(accounts.first { $0.id == Int(idBare) })

        XCTAssertEqual(withEmail.displayName, "me@gmail.com")
        XCTAssertEqual(bare.displayName, "Google account #\(idBare)")
    }
}
