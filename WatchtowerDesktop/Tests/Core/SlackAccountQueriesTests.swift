import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class SlackAccountQueriesTests: XCTestCase {

    private func makePool() throws -> DatabasePool {
        let (pool, _) = try TestDatabase.createPool()
        return pool
    }

    func testFetchAllRoundTripsSeededRowsOrderedByID() throws {
        let pool = try makePool()
        let secondID = try pool.write { db -> Int64 in
            _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme", label: "Work")
            return try TestDatabase.insertSlackAccount(db, teamName: "Personal Team", label: "Personal")
        }

        let accounts = try pool.read { db in try SlackAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 2)
        // Ordered by id ASC — the earlier-inserted row comes first.
        XCTAssertEqual(accounts[0].teamName, "Acme")
        XCTAssertEqual(accounts[0].label, "Work")
        XCTAssertEqual(accounts[1].teamName, "Personal Team")
        XCTAssertEqual(accounts[1].label, "Personal")
        XCTAssertEqual(accounts[1].id, Int(secondID))
    }

    func testFetchAllEmptyWhenNoAccounts() throws {
        let pool = try makePool()
        let accounts = try pool.read { db in try SlackAccountQueries.fetchAll(db) }
        XCTAssertTrue(accounts.isEmpty)
    }

    func testFetchAllDecodesAllFields() throws {
        let pool = try makePool()
        try pool.write { db in
            _ = try TestDatabase.insertSlackAccount(
                db,
                teamID: "T123",
                teamName: "Acme",
                teamDomain: "acme",
                label: "Work",
                currentUserID: "1:U042",
                status: "error",
                error: "token revoked",
                enabled: false
            )
        }

        let accounts = try pool.read { db in try SlackAccountQueries.fetchAll(db) }

        XCTAssertEqual(accounts.count, 1)
        let a = accounts[0]
        XCTAssertEqual(a.teamName, "Acme")
        XCTAssertEqual(a.teamDomain, "acme")
        XCTAssertEqual(a.label, "Work")
        XCTAssertEqual(a.status, "error")
        XCTAssertEqual(a.error, "token revoked")
        XCTAssertFalse(a.enabled)
        XCTAssertFalse(a.isOK)
        XCTAssertEqual(a.displayName, "Work")
    }

    func testEnabledDefaultsTrueAndStatusOK() throws {
        let pool = try makePool()
        try pool.write { db in
            _ = try TestDatabase.insertSlackAccount(db, teamName: "Acme")
        }
        let accounts = try pool.read { db in try SlackAccountQueries.fetchAll(db) }
        XCTAssertEqual(accounts.count, 1)
        XCTAssertTrue(accounts[0].enabled)
        XCTAssertTrue(accounts[0].isOK)
    }

    func testDisplayNameFallsBackToTeamNameThenID() throws {
        let pool = try makePool()
        let idWithTeam = try pool.write { db in
            try TestDatabase.insertSlackAccount(db, teamName: "Acme", label: "")
        }
        let idBare = try pool.write { db in
            try TestDatabase.insertSlackAccount(db, teamName: "", label: "")
        }

        let accounts = try pool.read { db in try SlackAccountQueries.fetchAll(db) }
        let withTeam = try XCTUnwrap(accounts.first { $0.id == Int(idWithTeam) })
        let bare = try XCTUnwrap(accounts.first { $0.id == Int(idBare) })

        XCTAssertEqual(withTeam.displayName, "Acme")
        XCTAssertEqual(bare.displayName, "Slack account #\(idBare)")
    }
}
