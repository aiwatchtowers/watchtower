import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ExtSourceQueriesTests: XCTestCase {

    private var path: String = ""

    override func tearDownWithError() throws {
        if !path.isEmpty {
            TestDatabase.cleanup(path: path)
        }
        try super.tearDownWithError()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, dbPath) = try TestDatabase.createPool()
        path = dbPath
        return pool
    }

    func testFetchForJiraAccountScopesToAccountOrderedByName() throws {
        let pool = try makePool()
        let (acct1, acct2) = try pool.write { db -> (Int64, Int64) in
            let a1 = try TestDatabase.insertJiraAccount(db, siteName: "Acme")
            let a2 = try TestDatabase.insertJiraAccount(db, siteName: "Other")
            // Inserted out of name order: the query must sort, not echo rowid order.
            try TestDatabase.insertExtSource(
                db, jiraAccountID: a1, containerKey: "OPS", containerName: "Операції",
                status: "error", error: "HTTP 500 from /wiki/api/v2/pages?limit=100&cursor=abc",
                backfillDone: true, lastSyncedAt: "2026-09-20T10:00:00Z"
            )
            try TestDatabase.insertExtSource(db, jiraAccountID: a1, containerKey: "ENG", containerName: "Engineering")
            try TestDatabase.insertExtSource(db, jiraAccountID: a2, containerKey: "ENG", containerName: "Eng (other site)")
            return (a1, a2)
        }

        let rows = try pool.read { db in try ExtSourceQueries.fetchForJiraAccount(db, accountID: acct1) }

        XCTAssertEqual(rows.map(\.containerKey), ["ENG", "OPS"])
        XCTAssertTrue(rows.allSatisfy { $0.jiraAccountID == acct1 })
        let ops = rows[1]
        XCTAssertEqual(ops.containerName, "Операції")
        XCTAssertEqual(ops.status, "error")
        XCTAssertEqual(ops.error, "HTTP 500 from /wiki/api/v2/pages?limit=100&cursor=abc")
        XCTAssertTrue(ops.backfillDone)
        XCTAssertEqual(ops.lastSyncedAt, "2026-09-20T10:00:00Z")
        XCTAssertFalse(rows[0].backfillDone)
        XCTAssertEqual(rows[0].lastSyncedAt, "")

        let other = try pool.read { db in try ExtSourceQueries.fetchForJiraAccount(db, accountID: acct2) }
        XCTAssertEqual(other.map(\.containerName), ["Eng (other site)"])
    }

    func testFetchForJiraAccountEmptyWhenNothingSelected() throws {
        let pool = try makePool()
        let acct = try pool.write { db in try TestDatabase.insertJiraAccount(db) }
        let rows = try pool.read { db in try ExtSourceQueries.fetchForJiraAccount(db, accountID: acct) }
        XCTAssertTrue(rows.isEmpty)
    }

    func testDocumentCountCountsEveryKindOfOneSourceOnly() throws {
        let pool = try makePool()
        let (src, sibling) = try pool.write { db -> (Int64, Int64) in
            let acct = try TestDatabase.insertJiraAccount(db)
            let src = try TestDatabase.insertExtSource(db, jiraAccountID: acct, containerKey: "ENG")
            let sibling = try TestDatabase.insertExtSource(db, jiraAccountID: acct, containerKey: "OPS")
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "101", kind: "page")
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "102", kind: "page")
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "201", kind: "blogpost")
            try TestDatabase.insertExtDocument(db, sourceID: src, extID: "att301", kind: "attachment")
            try TestDatabase.insertExtDocument(db, sourceID: sibling, extID: "101", kind: "page")
            return (src, sibling)
        }

        let count = try pool.read { db in try ExtSourceQueries.documentCount(db, sourceID: src) }
        XCTAssertEqual(count, 4)
        let siblingCount = try pool.read { db in try ExtSourceQueries.documentCount(db, sourceID: sibling) }
        XCTAssertEqual(siblingCount, 1)
        let none = try pool.read { db in try ExtSourceQueries.documentCount(db, sourceID: 9_999) }
        XCTAssertEqual(none, 0)
    }
}
