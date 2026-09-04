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
    func testAcknowledgeMarksWindowReadOnFiveSurfaces() throws {
        let dbQueue = try TestDatabase.create()
        let recapID = try dbQueue.write { db -> Int64 in
            try TestDatabase.insertDigest(db, periodFrom: base + 1500, periodTo: base + 1600)
            // Straddles the window start — the gather cites it, so the ack marks it.
            try TestDatabase.insertDigest(db, periodFrom: base + 500, periodTo: base + 1200)
            // Produced by the run's own top-up: period_to carries its own now(),
            // landing a second past the window's `to`.
            try TestDatabase.insertDigest(db, periodFrom: base + 1900, periodTo: base + 2001)
            _ = try TestDatabase.insertStreamDigest(
                db, periodFrom: "2027-01-15T12:25:00Z", periodTo: "2027-01-15T12:26:40Z"
            )
            _ = try TestDatabase.insertStreamDigest(
                db, periodFrom: "2027-01-15T12:08:20Z", periodTo: "2027-01-15T12:20:00Z"
            )
            _ = try TestDatabase.insertStreamDigest(
                db, periodFrom: "2027-01-15T12:31:40Z", periodTo: "2027-01-15T12:33:21Z"
            )
            let trackID = try TestDatabase.insertTrack(db, hasUpdates: true)
            try db.execute(
                sql: "UPDATE tracks SET updated_at = ? WHERE id = ?",
                arguments: ["2027-01-15T12:25:00Z", trackID]
            )
            let itemID = try TestDatabase.insertInboxItem(db)
            try db.execute(
                sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?",
                arguments: ["2027-01-15T12:25:00Z", itemID]
            )
            try TestDatabase.insertBriefing(db, date: localDate(base + 1500))
            return try insertRecap(db, from: base + 1000, to: base + 2000)
        }

        let recap = try fetchRecap(dbQueue, recapID)
        try dbQueue.write { db in try CatchUpQueries.acknowledge(db, recap: recap) }

        try dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests WHERE read_at IS NOT NULL"),
                3,
                "every digest overlapping the window — inside, straddling the start, and the top-up ending past `to`"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_digests WHERE read_at IS NOT NULL"),
                3,
                "the same three overlap cases on the stream surface"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE read_at IS NOT NULL AND has_updates = 0"),
                1,
                "tracks are marked read and lose their update flag"
            )
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items WHERE read_at IS NOT NULL"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM briefings WHERE read_at IS NOT NULL"), 1)

            let ack = try String.fetchOne(
                db, sql: "SELECT acknowledged_at FROM catchup_recaps WHERE id = ?", arguments: [recapID]
            )
            XCTAssertNotNil(ack, "the recap stamps its own acknowledged_at")
        }

        let reloaded = try fetchRecap(dbQueue, recapID)
        XCTAssertTrue(reloaded.isAcknowledged)
    }

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    func testAcknowledgeLeavesItemsOutsideWindowUnread() throws {
        let dbQueue = try TestDatabase.create()
        let recapID = try dbQueue.write { db -> Int64 in
            try TestDatabase.insertDigest(db, periodFrom: base + 1500, periodTo: base + 1600, summary: "in")
            // Starts at/after the window's `to` — no overlap, so no ack.
            try TestDatabase.insertDigest(db, periodFrom: base + 2500, periodTo: base + 2600, summary: "out")
            // Overlaps the window, but a daily roll-up is not a catch-up surface.
            try TestDatabase.insertDigest(
                db, periodFrom: base + 1500, periodTo: base + 1600, type: "daily", summary: "daily"
            )
            _ = try TestDatabase.insertStreamDigest(
                db, periodFrom: "2027-01-15T12:41:40Z", periodTo: "2027-01-15T12:43:20Z"
            )
            let itemID = try TestDatabase.insertInboxItem(db)
            try db.execute(
                sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?",
                arguments: ["2027-01-15T13:00:00Z", itemID]
            )
            return try insertRecap(db, from: base + 1000, to: base + 2000)
        }

        let recap = try fetchRecap(dbQueue, recapID)
        try dbQueue.write { db in try CatchUpQueries.acknowledge(db, recap: recap) }

        try dbQueue.read { db in
            let inRead = try String.fetchOne(db, sql: "SELECT read_at FROM digests WHERE summary = 'in'")
            XCTAssertNotNil(inRead, "in-window digest read")
            let outRead = try String.fetchOne(db, sql: "SELECT read_at FROM digests WHERE summary = 'out'")
            XCTAssertNil(outRead, "digest starting after the window stays unread")
            let dailyRead = try String.fetchOne(db, sql: "SELECT read_at FROM digests WHERE summary = 'daily'")
            XCTAssertNil(dailyRead, "a non-channel digest is not a catch-up surface")
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stream_digests WHERE read_at IS NOT NULL"),
                0,
                "stream digest starting after the window stays unread"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inbox_items WHERE read_at IS NOT NULL"),
                0,
                "inbox item created after the window stays unread"
            )
        }
    }

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    //
    // `to` is an EXCLUSIVE instant, so a window ending exactly on a local
    // midnight (what the `yesterday` preset resolves to) covers the day BEFORE
    // it: the briefing dated the day the window ends on must stay unread.
    func testAcknowledgeMarksWindowReadOnMidnightTo() throws {
        let dbQueue = try TestDatabase.create()
        // Midnight in the RUNNING time zone — `briefings.date` is a local
        // calendar date, so the fixture is derived the way the query is.
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: base))
        let dayBefore = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: midnight))
        let endDate = localDate(midnight.timeIntervalSince1970)
        let coveredDate = localDate(dayBefore.timeIntervalSince1970)

        let recapID = try dbQueue.write { db -> Int64 in
            try TestDatabase.insertBriefing(db, date: coveredDate)
            try TestDatabase.insertBriefing(db, date: endDate)
            return try insertRecap(
                db, from: dayBefore.timeIntervalSince1970, to: midnight.timeIntervalSince1970
            )
        }

        let recap = try fetchRecap(dbQueue, recapID)
        try dbQueue.write { db in try CatchUpQueries.acknowledge(db, recap: recap) }

        try dbQueue.read { db in
            XCTAssertNotNil(
                try String.fetchOne(db, sql: "SELECT read_at FROM briefings WHERE date = ?", arguments: [coveredDate]),
                "the day the window actually covers is marked read"
            )
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT read_at FROM briefings WHERE date = ?", arguments: [endDate]),
                "the briefing for the day the window ENDS on stays unread"
            )
        }
    }

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    //
    // "I'm caught up" on a recap that never finished would mark its whole window
    // read without the operator ever having been shown what was in it. The Go
    // twin (`Pipeline.Acknowledge`) refuses the same way.
    func testAcknowledgeRefusesRecapThatIsNotReady() throws {
        let dbQueue = try TestDatabase.create()
        let ids = try dbQueue.write { db -> [Int64] in
            try TestDatabase.insertDigest(db, periodFrom: base + 1500, periodTo: base + 1600)
            return [
                try insertRecap(db, from: base + 1000, to: base + 2000, status: "building"),
                try insertRecap(db, from: base + 1000, to: base + 2000, status: "failed")
            ]
        }

        for id in ids {
            let recap = try fetchRecap(dbQueue, id)
            XCTAssertThrowsError(
                try dbQueue.write { db in try CatchUpQueries.acknowledge(db, recap: recap) }
            ) { error in
                guard case CatchUpQueries.AcknowledgeError.notReady = error else {
                    return XCTFail("expected notReady for a \(recap.status) recap, got \(error)")
                }
            }
        }

        try dbQueue.read { db in
            XCTAssertNil(
                try String.fetchOne(db, sql: "SELECT read_at FROM digests"),
                "a refused acknowledge marks nothing read"
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM catchup_recaps WHERE acknowledged_at IS NOT NULL"),
                0,
                "and stamps no recap"
            )
        }
    }

    // BEHAVIOR CATCHUP-01 — see docs/inventory/catchup.md
    func testAcknowledgeIsIdempotent() throws {
        let dbQueue = try TestDatabase.create()
        let recapID = try dbQueue.write { db -> Int64 in
            try TestDatabase.insertDigest(db, periodFrom: base + 1500, periodTo: base + 1600)
            try db.execute(sql: "UPDATE digests SET read_at = '2020-01-01T00:00:00Z'")
            return try insertRecap(db, from: base + 1000, to: base + 2000)
        }

        let recap = try fetchRecap(dbQueue, recapID)
        try dbQueue.write { db in try CatchUpQueries.acknowledge(db, recap: recap) }
        XCTAssertNotNil(
            try dbQueue.read {
                try String.fetchOne($0, sql: "SELECT acknowledged_at FROM catchup_recaps WHERE id = ?", arguments: [recapID])
            }
        )

        // Both acks land in the same wall-clock second, so an equal stamp would
        // prove nothing: rewrite it to a sentinel the second ack could only keep
        // if its `acknowledged_at IS NULL` guard holds.
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE catchup_recaps SET acknowledged_at = '2020-06-01T00:00:00Z' WHERE id = ?",
                arguments: [recapID]
            )
        }

        let acknowledged = try fetchRecap(dbQueue, recapID)
        try dbQueue.write { db in try CatchUpQueries.acknowledge(db, recap: acknowledged) }

        try dbQueue.read { db in
            let stamp = try String.fetchOne(
                db, sql: "SELECT acknowledged_at FROM catchup_recaps WHERE id = ?", arguments: [recapID]
            )
            XCTAssertEqual(stamp, "2020-06-01T00:00:00Z", "second ack keeps the first stamp")
            let digestRead = try String.fetchOne(db, sql: "SELECT read_at FROM digests")
            XCTAssertEqual(digestRead, "2020-01-01T00:00:00Z", "already-read rows keep their stamp")
        }
    }
}
