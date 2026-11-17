import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class CatchUpQueriesTests: XCTestCase {

    // MARK: - Fixtures

    /// 2027-01-15T12:00:00Z — the same base the Go guard uses
    /// (`internal/db/catchup_store_test.go::catchupWindowBase`). Windows hang off
    /// a mid-day instant so the briefing predicate's LOCAL date cannot flip a day
    /// in any time zone the suite runs in.
    private let base: Double = 1_800_014_400

    private func insertRecap(
        _ db: Database,
        from: Double,
        to: Double,
        status: String = "ready",
        ack: String? = nil
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO catchup_recaps (period_from, period_to, status, acknowledged_at)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [from, to, status, ack]
        )
        return db.lastInsertedRowID
    }

    /// `briefings.date` is a LOCAL calendar date, so the fixture is derived with
    /// the same conversion the implementation applies to the window bounds.
    private func localDate(_ unix: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: unix))
    }

    private func fetchRecap(_ dbQueue: DatabaseQueue, _ id: Int64) throws -> CatchUpRecap {
        try XCTUnwrap(try dbQueue.read { try CatchUpQueries.fetchRecap($0, id: Int(id)) })
    }

    // MARK: - Fetch

    func testFetchRecapsNewestFirstAndFetchRecap() throws {
        let dbQueue = try TestDatabase.create()
        let ids = try dbQueue.write { db -> [Int64] in
            let older = try insertRecap(db, from: base, to: base + 1000, status: "ready")
            let newer = try insertRecap(db, from: base + 1000, to: base + 2000, status: "building")
            return [older, newer]
        }

        let recaps = try dbQueue.read { try CatchUpQueries.fetchRecaps($0) }
        XCTAssertEqual(recaps.map(\.id), [Int(ids[1]), Int(ids[0])], "newest first")
        XCTAssertTrue(recaps[0].isBuilding)
        XCTAssertTrue(recaps[1].isReady)
        XCTAssertFalse(recaps[1].isAcknowledged)

        XCTAssertEqual(try dbQueue.read { try CatchUpQueries.fetchRecaps($0, limit: 1) }.count, 1)

        let one = try fetchRecap(dbQueue, ids[0])
        XCTAssertEqual(one.periodFrom, base)
        XCTAssertEqual(one.periodTo, base + 1000)
        XCTAssertNil(one.regenOfID)
        XCTAssertNil(one.acknowledgedAt)
        XCTAssertTrue(one.decodedBody.isEmpty, "default body_json '{}' decodes to an empty body")

        XCTAssertNil(try dbQueue.read { try CatchUpQueries.fetchRecap($0, id: 9999) })
    }

    func testAutoWindowStartUsesLastAcknowledged() throws {
        let dbQueue = try TestDatabase.create()
        XCTAssertNil(try dbQueue.read { try CatchUpQueries.autoWindowStart($0) }, "no recaps → nil")

        try dbQueue.write { db in
            // Latest period_to overall, but never acknowledged.
            _ = try insertRecap(db, from: base, to: base + 5000)
        }
        XCTAssertNil(
            try dbQueue.read { try CatchUpQueries.autoWindowStart($0) },
            "an unacknowledged recap does not move the boundary"
        )

        try dbQueue.write { db in
            _ = try insertRecap(db, from: base, to: base + 1000, ack: "2027-01-15T12:20:00Z")
            _ = try insertRecap(db, from: base, to: base + 3000, ack: "2027-01-15T12:50:00Z")
        }
        let start = try dbQueue.read { try CatchUpQueries.autoWindowStart($0) }
        XCTAssertEqual(start?.timeIntervalSince1970, base + 3000)
    }

    func testHasUnacknowledgedReady() throws {
        let dbQueue = try TestDatabase.create()
        XCTAssertFalse(try dbQueue.read { try CatchUpQueries.hasUnacknowledgedReady($0) }, "no recaps")

        try dbQueue.write { db in
            _ = try insertRecap(db, from: base, to: base + 1000, status: "building")
            _ = try insertRecap(db, from: base, to: base + 1000, status: "ready", ack: "2027-01-15T12:20:00Z")
        }
        XCTAssertFalse(
            try dbQueue.read { try CatchUpQueries.hasUnacknowledgedReady($0) },
            "still building, or already acknowledged, does not count"
        )

        try dbQueue.write { db in
            _ = try insertRecap(db, from: base + 1000, to: base + 2000, status: "ready")
        }
        XCTAssertTrue(try dbQueue.read { try CatchUpQueries.hasUnacknowledgedReady($0) })
    }

    // MARK: - Acknowledge (window-scoped mark-read)

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    //

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    //

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    //

}
