import XCTest
import GRDB
@testable import WatchtowerDesktop

final class JiraAccountQueriesTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (manager, _) = try TestDatabase.createDatabaseManager()
        return manager.dbPool
    }

    func testFetchAllRoundTripsSeededRowsOrderedByID() throws {
        let pool = try makePool()
        let secondID = try pool.write { db -> Int64 in
            _ = try TestDatabase.insertJiraAccount(db, siteName: "Acme", label: "Work")
            return try TestDatabase.insertJiraAccount(db, siteName: "Client", label: "Client")
        }

        let accounts = try pool.read { db in try JiraAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 2)
        // Ordered by id ASC — the earlier-inserted row comes first.
        XCTAssertEqual(accounts[0].siteName, "Acme")
        XCTAssertEqual(accounts[0].label, "Work")
        XCTAssertEqual(accounts[1].siteName, "Client")
        XCTAssertEqual(accounts[1].id, Int(secondID))
    }

    func testFetchAllSkipsRemovedAccounts() throws {
        let pool = try makePool()
        try pool.write { db in
            // `jira remove` keeps the row so historical issues stay
            // attributable — the account list must not show it anyway.
            _ = try TestDatabase.insertJiraAccount(
                db, siteName: "Gone", status: "removed", enabled: false
            )
            _ = try TestDatabase.insertJiraAccount(db, siteName: "Acme")
        }

        let accounts = try pool.read { db in try JiraAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.map(\.siteName), ["Acme"])
    }

    func testFetchAllEmptyWhenNoAccounts() throws {
        let pool = try makePool()
        let accounts = try pool.read { db in try JiraAccountQueries.fetchAll(db) }
        XCTAssertTrue(accounts.isEmpty)
    }

    func testFetchAllDecodesAllFields() throws {
        let pool = try makePool()
        try pool.write { db in
            _ = try TestDatabase.insertJiraAccount(
                db,
                cloudID: "cloud-1",
                siteURL: "https://acme.atlassian.net",
                siteName: "Acme",
                label: "Work",
                status: "error",
                error: "token revoked",
                enabled: false
            )
        }

        let accounts = try pool.read { db in try JiraAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 1)
        let a = accounts[0]
        XCTAssertEqual(a.cloudID, "cloud-1")
        XCTAssertEqual(a.siteURL, "https://acme.atlassian.net")
        XCTAssertEqual(a.siteName, "Acme")
        XCTAssertEqual(a.label, "Work")
        XCTAssertEqual(a.status, "error")
        XCTAssertEqual(a.error, "token revoked")
        XCTAssertFalse(a.enabled)
        XCTAssertFalse(a.isOK)
        XCTAssertEqual(a.displayName, "Work")
    }

    func testDisplayNameFallsBackToSiteNameThenID() throws {
        let pool = try makePool()
        let idWithSite = try pool.write { db in
            try TestDatabase.insertJiraAccount(db, siteName: "Acme", label: "")
        }
        let idBare = try pool.write { db in
            try TestDatabase.insertJiraAccount(db, siteName: "", label: "")
        }

        let accounts = try pool.read { db in try JiraAccountQueries.fetchAll(db) }
        let withSite = try XCTUnwrap(accounts.first { $0.id == Int(idWithSite) })
        let bare = try XCTUnwrap(accounts.first { $0.id == Int(idBare) })

        XCTAssertEqual(withSite.displayName, "Acme")
        XCTAssertEqual(bare.displayName, "Jira account #\(idBare)")
    }

    // MARK: - primarySiteURL

    func testPrimarySiteURLPicksFirstEnabledResolvedAccount() throws {
        let pool = try makePool()
        try pool.write { db in
            // Removed, disabled, and unresolved rows are all skipped.
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://removed.atlassian.net", status: "removed", enabled: false)
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://disabled.atlassian.net", enabled: false)
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "")
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://acme.atlassian.net")
            _ = try TestDatabase.insertJiraAccount(db, siteURL: "https://second.atlassian.net")
        }

        let url = try pool.read { db in try JiraAccountQueries.primarySiteURL(db) }
        XCTAssertEqual(url, "https://acme.atlassian.net")
    }

    func testPrimarySiteURLNilWhenNoAccounts() throws {
        let pool = try makePool()
        let url = try pool.read { db in try JiraAccountQueries.primarySiteURL(db) }
        XCTAssertNil(url)
    }
}
