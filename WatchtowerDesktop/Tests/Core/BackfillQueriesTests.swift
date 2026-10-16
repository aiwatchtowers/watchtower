import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class BackfillQueriesTests: XCTestCase {
    func testRowsReadInsertedRowsInIdOrder() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO history_backfill
                (id, source_kind, account_id, floor_ts, upper_ts, reached_ts, status, waiting, started_at, updated_at)
                VALUES
                (2, 'gmail', 1, 100, 400, 300, 'paused', 'plan_limit', '2026-10-15T08:00:00Z', '2026-10-15T08:00:00Z'),
                (1, 'slack', 1, 1000, 2000, 1500, 'running', '', '2026-10-15T08:00:00Z', '2026-10-15T08:00:00Z'),
                (3, 'jira', 1, 10, 40, 40, 'running', '', '2026-10-15T08:00:00Z', '2026-10-15T08:00:00Z')
                """)
        }
        let rows = try db.read { try BackfillQueries.rows($0) }
        XCTAssertEqual(rows, [
            BackfillRow(status: "running", waiting: "", floorTS: 1000, upperTS: 2000, reachedTS: 1500),
            BackfillRow(status: "paused", waiting: "plan_limit", floorTS: 100, upperTS: 400, reachedTS: 300),
            BackfillRow(status: "running", waiting: "", floorTS: 10, upperTS: 40, reachedTS: 40)
        ])
    }

    func testRowsEmptyWithoutBackfills() throws {
        let db = try TestDatabase.create()
        XCTAssertEqual(try db.read { try BackfillQueries.rows($0) }, [])
    }
}
