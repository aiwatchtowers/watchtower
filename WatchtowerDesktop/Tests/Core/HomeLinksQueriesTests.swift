import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The read behind Home's links zone.
final class HomeLinksQueriesTests: XCTestCase {
    private var db: DatabaseQueue!
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }
    private let now = Date(timeIntervalSince1970: 1_792_400_000) // 2026-10-19 UTC

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func read() throws -> HomeLinksData {
        try db.read { HomeLinksQueries.read($0, now: self.now, calendar: self.calendar) }
    }

    func testTodayVersusLatestBriefing() throws {
        try db.write { try TestDatabase.insertBriefing($0, date: "2026-10-16") }
        var data = try read()
        XCTAssertNil(data.briefingToday)
        XCTAssertEqual(data.latestBriefing?.date, "2026-10-16")
        try db.write { try TestDatabase.insertBriefing($0, userID: "U2", date: "2026-10-19") }
        data = try read()
        XCTAssertEqual(data.briefingToday?.date, "2026-10-19")
        XCTAssertFalse(data.failed)
    }

    func testPlanCountsAndPendingRecap() throws {
        try db.write { d in
            let plan = try TestDatabase.insertDayPlan(d, planDate: "2026-10-19")
            _ = try TestDatabase.insertDayPlanItem(d, dayPlanID: plan, status: "done")
            _ = try TestDatabase.insertDayPlanItem(d, dayPlanID: plan, status: "pending")
            _ = try TestDatabase.insertDayPlanItem(d, dayPlanID: plan, status: "skipped")
            try d.execute(sql: "INSERT INTO catchup_recaps (period_from, period_to, status) VALUES (1, 2, 'ready')")
        }
        let data = try read()
        XCTAssertEqual(data.dayPlanDone, 1)
        XCTAssertEqual(data.dayPlanTotal, 3)
        XCTAssertNotNil(data.pendingRecap)
    }

    func testMissingTableReadsAsNil() throws {
        try db.write { try $0.execute(sql: "DROP TABLE catchup_recaps") }
        let data = try read()
        XCTAssertNil(data.pendingRecap)
        XCTAssertFalse(data.failed)
    }

    /// The Catch-Up badge's recap: a newer building or failed recap (or an
    /// acknowledged one) does not hide an older ready, unacknowledged one.
    func testPendingRecapIsNewestReadyUnacknowledged() throws {
        try db.write { d in
            let sql = "INSERT INTO catchup_recaps (period_from, period_to, status, tldr, acknowledged_at) VALUES (?, ?, ?, ?, ?)"
            let to = self.now.timeIntervalSince1970
            try d.execute(sql: sql, arguments: [to - 7200, to - 3600, "ready", "Older ready", nil])
            try d.execute(sql: sql, arguments: [to - 3600, to - 1800, "ready", "Acknowledged", "2026-10-19T00:00:00Z"])
            try d.execute(sql: sql, arguments: [to - 1800, to, "failed", "Failed", nil])
            try d.execute(sql: sql, arguments: [to - 1800, to, "building", "Building", nil])
        }
        XCTAssertEqual(try read().pendingRecap?.tldr, "Older ready")
    }
}
