import XCTest
import GRDB
@testable import WatchtowerDesktop

final class EmailAccountQueriesTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    func testFetchAllRoundTripsSeededRowsOrderedByCreatedAt() throws {
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertEmailAccount(
                db, provider: "outlook", emailAddress: "b@outlook.com",
                createdAt: "2026-02-01T00:00:00Z"
            )
            try TestDatabase.insertEmailAccount(
                db, provider: "imap", emailAddress: "a@example.com",
                createdAt: "2026-01-01T00:00:00Z"
            )
        }

        let accounts = try pool.read { db in try EmailAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 2)
        // Ordered by created_at ASC — the earlier-created row comes first,
        // regardless of insertion order.
        XCTAssertEqual(accounts[0].emailAddress, "a@example.com")
        XCTAssertEqual(accounts[0].provider, "imap")
        XCTAssertEqual(accounts[1].emailAddress, "b@outlook.com")
        XCTAssertEqual(accounts[1].provider, "outlook")
    }

    func testFetchAllEmptyWhenNoAccounts() throws {
        let pool = try makePool()
        let accounts = try pool.read { db in try EmailAccountQueries.fetchAll(db) }
        XCTAssertTrue(accounts.isEmpty)
    }

    func testFetchAllDecodesAllFields() throws {
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertEmailAccount(
                db, provider: "imap", emailAddress: "me@example.com",
                host: "imap.example.com", port: 993, security: "ssl",
                folder: "Archive", label: "Work", status: "error", error: "bad password"
            )
        }

        let accounts = try pool.read { db in try EmailAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 1)
        let a = accounts[0]
        XCTAssertEqual(a.host, "imap.example.com")
        XCTAssertEqual(a.port, 993)
        XCTAssertEqual(a.security, "ssl")
        XCTAssertEqual(a.folder, "Archive")
        XCTAssertEqual(a.label, "Work")
        XCTAssertEqual(a.status, "error")
        XCTAssertEqual(a.error, "bad password")
        XCTAssertFalse(a.isOK)
        XCTAssertFalse(a.isOutlook)
        XCTAssertEqual(a.displayName, "Work")
    }
}
