import XCTest
import GRDB
@testable import WatchtowerDesktop

final class CalendarAccountQueriesTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    func testFetchAllRoundTripsSeededRowsOrderedByCreatedAt() throws {
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertCalendarAccount(
                db, provider: "ics", username: "", url: "", label: "Family",
                createdAt: "2026-02-01T00:00:00Z"
            )
            try TestDatabase.insertCalendarAccount(
                db, provider: "caldav", username: "a@icloud.com", url: "https://caldav.icloud.com",
                createdAt: "2026-01-01T00:00:00Z"
            )
        }

        let accounts = try pool.read { db in try CalendarAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 2)
        // Ordered by created_at ASC — the earlier-created row comes first,
        // regardless of insertion order.
        XCTAssertEqual(accounts[0].username, "a@icloud.com")
        XCTAssertEqual(accounts[0].provider, "caldav")
        XCTAssertEqual(accounts[1].label, "Family")
        XCTAssertEqual(accounts[1].provider, "ics")
    }

    func testFetchAllEmptyWhenNoAccounts() throws {
        let pool = try makePool()
        let accounts = try pool.read { db in try CalendarAccountQueries.fetchAll(db) }
        XCTAssertTrue(accounts.isEmpty)
    }

    func testFetchAllDecodesAllFields() throws {
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertCalendarAccount(
                db, provider: "caldav", username: "me@icloud.com",
                url: "https://caldav.icloud.com", label: "Personal",
                status: "error", error: "401 unauthorized"
            )
        }

        let accounts = try pool.read { db in try CalendarAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 1)
        let a = accounts[0]
        XCTAssertEqual(a.username, "me@icloud.com")
        XCTAssertEqual(a.url, "https://caldav.icloud.com")
        XCTAssertEqual(a.label, "Personal")
        XCTAssertEqual(a.status, "error")
        XCTAssertEqual(a.error, "401 unauthorized")
        XCTAssertFalse(a.isOK)
        XCTAssertFalse(a.isICS)
        XCTAssertEqual(a.displayName, "Personal")
    }

    func testDisplayNameFallsBackToUsernameThenICSFeed() throws {
        let pool = try makePool()
        try pool.write { db in
            try TestDatabase.insertCalendarAccount(
                db, provider: "caldav", username: "me@fastmail.com",
                url: "https://caldav.fastmail.com", label: "",
                createdAt: "2026-01-01T00:00:00Z"
            )
            // ics rows have no username and store NO url (the secret feed URL
            // is a credential and never lands in the DB).
            try TestDatabase.insertCalendarAccount(
                db, provider: "ics", username: "", url: "", label: "",
                createdAt: "2026-02-01T00:00:00Z"
            )
        }

        let accounts = try pool.read { db in try CalendarAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts[0].displayName, "me@fastmail.com")
        XCTAssertEqual(accounts[1].displayName, "ICS feed")
        XCTAssertTrue(accounts[1].isICS)
        XCTAssertTrue(accounts[1].url.isEmpty)
    }
}
