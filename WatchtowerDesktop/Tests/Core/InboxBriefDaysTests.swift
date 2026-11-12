import GRDB
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The Morning brief's History (the last 30 dates, today included) and the
/// stepper's moves, and the first page of the read that both rely on.
final class InboxBriefDaysTests: XCTestCase {
    private static let kyiv: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .current
        return calendar
    }()

    private static let today = "2026-11-11"

    /// Wed 11 Nov 2026, 08:02 in Kyiv (UTC+2).
    private func now() throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-11T06:02:00Z"))
    }

    private func day(_ date: String) throws -> InboxDayCard {
        let briefing = try Briefing(row: Row([
            "id": 1, "user_id": "u", "date": date, "role": "", "attention": "[]", "your_day": "[]",
            "what_happened": "[]", "team_pulse": "[]", "coaching": "[]", "model": "", "input_tokens": 0,
            "output_tokens": 0, "cost_usd": 0.0, "prompt_version": 1, "read_at": nil,
            "created_at": "\(date)T05:00:00Z"
        ] as [String: (any DatabaseValueConvertible)?]))
        return InboxDayCard(date: date, briefing: briefing, plan: nil, planDone: 0, planTotal: 0, stamp: try now())
    }

    func testHistoryIsThirtyDaysNewestFirst() throws {
        let days = [
            try day("2026-10-12"),
            try day("2026-11-09"),
            try day(Self.today),
            try day("2026-10-13"),
            .placeholder(date: "2026-11-10", stamp: try now())
        ]
        let history = InboxBriefDays.history(days, today: Self.today, now: try now(), calendar: Self.kyiv)
        XCTAssertEqual(history.map(\.date), [Self.today, "2026-11-09", "2026-10-13"],
                       "today included, nothing written left out, the 31st date back left out")
    }

    func testStepOlderSkipsDaysWithoutACard() throws {
        let days = [try day(Self.today), try day("2026-11-08"), .placeholder(date: "2026-11-09", stamp: try now())]
        XCTAssertEqual(InboxBriefDays.step(from: Self.today, .older, in: days, today: Self.today), "2026-11-08")
        XCTAssertNil(InboxBriefDays.step(from: "2026-11-08", .older, in: days, today: Self.today), "past the end")
    }

    func testStepNewerStopsAtToday() throws {
        let days = [try day("2026-11-12"), try day("2026-11-09")]
        XCTAssertEqual(InboxBriefDays.step(from: "2026-11-09", .newer, in: days, today: Self.today), Self.today,
                       "today counts with no card")
        XCTAssertNil(InboxBriefDays.step(from: Self.today, .newer, in: days, today: Self.today),
                     "a card dated after today is never reached")
    }

    func testStepFromThePlaceholderGoesToYesterday() throws {
        let days = [try day("2026-11-10"), try day("2026-11-01")]
        XCTAssertEqual(InboxBriefDays.step(from: Self.today, .older, in: days, today: Self.today), "2026-11-10")
    }

    /// A briefing on each of 45 days: the first read holds all 30 of the
    /// last 30 dates, and the Earlier line counts the 29 past ones.
    @MainActor
    func testFirstPageCoversThirtyDays() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let suite = "InboxBriefDaysTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let dates = (0..<45).map { back in
            HomeFeedBuilder.dayString(calendar.date(byAdding: .day, value: -back, to: start) ?? start, calendar: calendar)
        }
        try await pool.write { db in
            try InboxFolderFixtures.seed(db)
            for date in dates {
                try TestDatabase.insertBriefing(db, date: date)
            }
        }
        let vm = ActionStripViewModel(
            dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { now }, dayChangeSignals: [])

        await vm.refresh()

        XCTAssertEqual(vm.feed.days.map(\.date), Array(dates.prefix(30)))
        let history = InboxBriefDays.history(vm.feed.days, today: dates[0], now: now, calendar: calendar)
        XCTAssertEqual(history.count, 30)
        XCTAssertEqual(vm.folderList.earlierLine?.pastThisMonth, 29)
    }
}
