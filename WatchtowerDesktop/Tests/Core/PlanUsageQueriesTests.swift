import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

final class PlanUsageQueriesTests: XCTestCase {
    func testStatusDecodesLimitsJSON() throws {
        let db = try TestDatabase.create()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO plan_usage_status (id, state, reason, plan, fetched_at, last_error, limits_json, breakdown_json, updated_at)
                VALUES (1, 'ok', '', 'max', '2026-10-15T08:00:00.123456789Z', '',
                 '[{"key":"session","label":"5-hour","group":"session","percent":4,
                    "resets_at":"2026-10-15T10:59:59Z","severity":"normal",
                    "projection":{"state":"will_hit","hit_at":"2026-10-15T09:30:00.987654321Z","rate_per_hour":12.5}}]',
                 '[{"key":"chat","label":"Chats","percent":10}]', '2026-10-15T08:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO plan_usage_samples VALUES
                ('2026-10-15T08:00:00Z','session',4,'2026-10-15T10:59:59Z'), ('2026-10-15T07:00:00Z','session',2,'')
                """)
        }
        let s = try db.read { try PlanUsageQueries.status($0) }
        XCTAssertEqual(s?.limits.first?.projection.state, "will_hit")
        XCTAssertEqual(s?.limits.first?.projection.ratePerHour, 12.5)
        XCTAssertNotNil(s?.limits.first?.projection.hitAt, "9-digit fraction parses")
        XCTAssertNotNil(s?.fetchedAt, "fractional seconds parse")
        XCTAssertEqual(s?.breakdown.first?.label, "Chats")
        let samples = try db.read { try PlanUsageQueries.samples($0, key: "session", since: .distantPast) }
        XCTAssertEqual(samples.count, 2)
        XCTAssertNil(samples.first?.resetsAt, "'' is nil")
    }

    func testStatusNilWithoutRow() throws {
        let db = try TestDatabase.create()
        XCTAssertNil(try db.read { try PlanUsageQueries.status($0) })
    }
}
