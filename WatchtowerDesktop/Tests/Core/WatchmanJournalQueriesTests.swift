import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The journal's reads over `watchman_items` / `watchman_gaps` (spec §10):
/// nights from noon to noon, Waiting for you, Checks nobody ran, gaps and cost.
final class WatchmanJournalQueriesTests: XCTestCase {
    /// The tests' local zone: UTC+1, so noon local is 11:00Z.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3600) ?? .gmt
        return calendar
    }()

    private func date(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }

    @discardableResult
    private func item(
        _ db: Database,
        workbench: Int64,
        created: String,
        kind: String = "ask",
        state: String = "done",
        outcome: String = "answered",
        unsure: Int = 1,
        feedback: String = "",
        checkDone: String? = nil,
        cost: Double = 0,
        question: String = "Q",
        parkReason: String = ""
    ) throws -> Int64 {
        let ref = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(ref_id), 0) + 1 FROM watchman_items") ?? 1
        try db.execute(sql: """
            INSERT INTO watchman_items (workbench_id, kind, ref_kind, ref_id, state, outcome, unsure, feedback,
                check_done_at, cost_usd, question, park_reason, created_at)
            VALUES (?, ?, 'ask', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [workbench, kind, ref, state, outcome, unsure, feedback, checkDone, cost, question,
                             parkReason, created])
        return db.lastInsertedRowID
    }

    private func nights(_ queue: DatabaseQueue, limit: Int = 10) throws -> [WatchmanNight] {
        let calendar = calendar
        return try queue.read { try WatchmanJournalQueries.nights($0, limit: limit, calendar: calendar) }
    }

    /// 11:59 local belongs to the night before; 12:00 local starts a new one.
    func testNightBoundaryAtNoon() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db, name: "acme-api")
            try item(db, workbench: wb, created: "2026-11-16T10:59:00Z", question: "before noon") // 11:59 local
            try item(db, workbench: wb, created: "2026-11-16T11:00:00Z", question: "at noon") // 12:00 local
            try item(db, workbench: wb, created: "2026-11-15T23:30:00Z", question: "after midnight") // 00:30 local
        }
        let nights = try nights(queue)
        XCTAssertEqual(nights.map(\.date), [date("2026-11-16T11:00:00Z"), date("2026-11-15T11:00:00Z")])
        XCTAssertEqual(nights[0].decided.map(\.question), ["at noon"])
        XCTAssertEqual(nights[1].decided.map(\.question), ["after midnight", "before noon"])
        XCTAssertEqual(nights[0].decided.first?.workbenchName, "acme-api")
        // The limit counts nights, newest first.
        XCTAssertEqual(try self.nights(queue, limit: 1).map(\.date), [date("2026-11-16T11:00:00Z")])
    }

    /// Waiting for you: parked and handed items the owner has not acknowledged.
    func testWaitingHoldsParkedAndHanded() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try item(db, workbench: wb, created: "2026-11-16T01:00:00Z", outcome: "parked", question: "parked",
                     parkReason: "merging to main is yours")
            try item(db, workbench: wb, created: "2026-11-16T01:10:00Z", outcome: "handed", question: "handed")
            try item(db, workbench: wb, created: "2026-11-16T01:20:00Z", outcome: "parked", feedback: "ok",
                     question: "parked, seen")
            try item(db, workbench: wb, created: "2026-11-16T01:30:00Z", outcome: "answered", question: "answered")
            try item(db, workbench: wb, created: "2026-11-16T01:40:00Z", state: "deciding", outcome: "",
                     question: "deciding")
        }
        let night = try XCTUnwrap(nights(queue).first)
        XCTAssertEqual(night.waiting.map(\.question), ["parked", "handed"])
        XCTAssertEqual(night.waiting.first?.parkReason, "merging to main is yours")
        XCTAssertEqual(night.decided.map(\.question), ["parked, seen", "answered"])
        XCTAssertEqual(night.pending.map(\.question), ["deciding"])
        let live = try queue.read { try WatchmanJournalQueries.liveDeciding($0) }
        XCTAssertEqual(live.map(\.question), ["deciding"])
        try queue.write { db in
            try db.execute(sql: "INSERT INTO watchman_workbenches (workbench_id, enabled_at) VALUES (1, '2026-11-10T00:00:00Z')")
        }
        let calendar = calendar
        let summary = try XCTUnwrap(queue.read { try WatchmanJournalQueries.inboxSummary($0, calendar: calendar) })
        XCTAssertEqual(summary.waiting, 2)
        XCTAssertEqual(summary.latest, WatchmanNightCounts(start: night.date, decided: 2, unsure: 2, waiting: 2))
        XCTAssertEqual(summary.updatedAt, date("2026-11-16T01:40:00Z"))
    }

    /// A check is listed until someone runs it; it never counts as decided.
    func testChecksListUntilDone() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try item(db, workbench: wb, created: "2026-11-16T02:00:00Z", kind: "check", question: "tray check")
            try item(db, workbench: wb, created: "2026-11-16T02:10:00Z", kind: "check",
                     checkDone: "2026-11-16T09:00:00Z", question: "ran")
        }
        let night = try XCTUnwrap(nights(queue).first)
        XCTAssertEqual(night.checks.map(\.question), ["tray check"])
        XCTAssertTrue(night.decided.isEmpty)
        try queue.write { db in
            try db.execute(sql: "UPDATE watchman_items SET check_done_at = '2026-11-16T09:30:00Z'")
        }
        XCTAssertEqual(try nights(queue).first?.checks, [])
    }

    /// Each night carries the gaps it overlaps and the cost of its own items.
    func testGapsAndCostPerNight() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try item(db, workbench: wb, created: "2026-11-16T01:00:00Z", cost: 1.25)
            try item(db, workbench: wb, created: "2026-11-16T03:00:00Z", outcome: "parked", cost: 0.75)
            try item(db, workbench: wb, created: "2026-11-15T01:00:00Z", cost: 2)
            try db.execute(sql: """
                INSERT INTO watchman_gaps (started_at, ended_at) VALUES
                    ('2026-11-16T01:10:00Z', '2026-11-16T02:00:00Z'),
                    ('2026-11-14T01:00:00Z', '2026-11-14T02:00:00Z')
                """)
        }
        let nights = try nights(queue)
        XCTAssertEqual(nights.map(\.costUSD), [2, 2])
        XCTAssertEqual(nights[0].gaps, [date("2026-11-16T01:10:00Z")...date("2026-11-16T02:00:00Z")])
        XCTAssertEqual(nights[1].gaps, [])
    }

    /// Home's row is last night's or tonight's, only when it did something.
    func testHomeNightIsLastNightOnly() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try item(db, workbench: wb, created: "2026-11-16T01:00:00Z")
            try item(db, workbench: wb, created: "2026-11-16T02:00:00Z", outcome: "parked")
        }
        let calendar = calendar
        func home(_ now: String) throws -> WatchmanNightCounts? {
            try queue.read { try WatchmanJournalQueries.homeNight($0, now: self.date(now), calendar: calendar) }
        }
        let start = date("2026-11-15T11:00:00Z")
        XCTAssertEqual(try home("2026-11-16T07:00:00Z"), WatchmanNightCounts(start: start, decided: 1, unsure: 1, waiting: 1))
        XCTAssertNotNil(try home("2026-11-16T15:00:00Z"), "the afternoon after still shows last night")
        XCTAssertNil(try home("2026-11-17T15:00:00Z"), "two nights later: gone")
    }

    func testPrecedentTitlesAreFirstLines() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try db.execute(sql: """
                INSERT INTO watchman_precedents (id, workbench_id, source, source_key, category, situation, decided_at)
                VALUES (7, ?, 'ask', 'a7', 'design', 'Sidebar width per workbench\nmore', '2026-11-01T00:00:00Z')
                """, arguments: [wb])
        }
        let titles = try queue.read { try WatchmanJournalQueries.precedentTitles($0, ids: [7, 8]) }
        XCTAssertEqual(titles, [7: "Sidebar width per workbench"])
    }

    /// Noon stays noon on DST days in Europe/Berlin: the spring-forward
    /// night is 23 h, the fall-back night 25 h, and each night ends where
    /// the next starts.
    func testNightBoundaryOnDSTDays() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        // 2026-03-29 02:00 CET → 03:00 CEST.
        let springStart = date("2026-03-28T11:00:00Z") // 12:00 CET
        let springEnd = date("2026-03-29T10:00:00Z") // 12:00 CEST
        XCTAssertEqual(WatchmanNight.start(of: date("2026-03-29T09:59:00Z"), calendar: berlin), springStart)
        XCTAssertEqual(WatchmanNight.start(of: springEnd, calendar: berlin), springEnd)
        XCTAssertEqual(WatchmanNight.end(of: springStart, calendar: berlin), springEnd)
        XCTAssertEqual(springEnd.timeIntervalSince(springStart), 23 * 3600)
        // 2026-10-25 03:00 CEST → 02:00 CET.
        let fallStart = date("2026-10-24T10:00:00Z") // 12:00 CEST
        let fallEnd = date("2026-10-25T11:00:00Z") // 12:00 CET
        XCTAssertEqual(WatchmanNight.start(of: date("2026-10-25T10:59:00Z"), calendar: berlin), fallStart)
        XCTAssertEqual(WatchmanNight.start(of: fallEnd, calendar: berlin), fallEnd)
        XCTAssertEqual(WatchmanNight.end(of: fallStart, calendar: berlin), fallEnd)
        XCTAssertEqual(fallEnd.timeIntervalSince(fallStart), 25 * 3600)
    }

    /// An empty tonight (only a queued item) does not hide last night.
    func testHomeNightSkipsAnEmptyTonight() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try item(db, workbench: wb, created: "2026-11-16T01:00:00Z") // last night
            try item(db, workbench: wb, created: "2026-11-16T13:00:00Z", state: "queued", outcome: "") // tonight
        }
        let calendar = calendar
        let counts = try queue.read {
            try WatchmanJournalQueries.homeNight($0, now: self.date("2026-11-16T15:00:00Z"), calendar: calendar)
        }
        XCTAssertEqual(counts, WatchmanNightCounts(start: date("2026-11-15T11:00:00Z"), decided: 1, unsure: 1, waiting: 0))
    }

    /// The owner answered first: not a decision, not counted, listed apart.
    func testOwnerFirstIsNotDecided() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            try item(db, workbench: wb, created: "2026-11-16T01:00:00Z", question: "decided")
            try item(db, workbench: wb, created: "2026-11-16T01:30:00Z", outcome: "owner_first", question: "owner")
        }
        let night = try XCTUnwrap(nights(queue).first)
        XCTAssertEqual(night.decided.map(\.question), ["decided"])
        XCTAssertEqual(night.ownerFirst.map(\.question), ["owner"])
        XCTAssertEqual(WatchmanNightCounts(night).decided, 1)
    }

    /// The bounded read still finds sparse nights in order and honours the limit.
    func testNightsReadOnlyTheNightsAsked() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            for day in ["2026-11-01", "2026-11-05", "2026-11-05", "2026-11-09", "2026-11-12"] {
                try item(db, workbench: wb, created: "\(day)T02:00:00Z")
            }
        }
        let starts = try nights(queue, limit: 3).map(\.date)
        XCTAssertEqual(starts, [date("2026-11-11T11:00:00Z"), date("2026-11-08T11:00:00Z"), date("2026-11-04T11:00:00Z")])
        XCTAssertEqual(try nights(queue, limit: 3)[2].decided.count, 2)
    }

    /// A malformed `precedent_ids` reads as no precedents, the row still shows.
    func testMalformedPrecedentsReadAsNone() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let wb = try TestDatabase.insertWorkbench(db)
            let id = try item(db, workbench: wb, created: "2026-11-16T01:00:00Z")
            try db.execute(sql: "UPDATE watchman_items SET precedent_ids = 'not json' WHERE id = ?", arguments: [id])
        }
        let night = try XCTUnwrap(nights(queue).first)
        XCTAssertEqual(night.decided.first?.precedentIDs, [])
    }
}
