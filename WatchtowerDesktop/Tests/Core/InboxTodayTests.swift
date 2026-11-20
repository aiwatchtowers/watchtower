import Foundation
import XCTest
@testable import WatchtowerCore

/// The Inbox "from today" rule over the fixture shared with Go
/// (`internal/inbox/testdata/from_today.json`).
final class InboxTodayTests: XCTestCase {
    func testFixtureCases() throws {
        let cases = try InboxTodayFixture.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 9)
        for item in cases {
            let mentioned = item.mentionedAt.flatMap { $0.isEmpty ? nil : $0 }
            let got = InboxToday.isFromToday(
                createdAt: try InboxTodayFixture.date(item.createdAt),
                mentionedAt: try mentioned.map { try InboxTodayFixture.date($0) },
                now: try InboxTodayFixture.date(item.now),
                calendar: try InboxTodayFixture.calendar(item.tz)
            )
            XCTAssertEqual(got, item.expected, item.name)
        }
    }

    func testStartOfTodayIsLocalMidnight() throws {
        let start = InboxToday.startOfToday(
            now: try InboxTodayFixture.date("2026-11-11T08:00:00Z"),
            calendar: try InboxTodayFixture.calendar("Europe/Kyiv")
        )
        XCTAssertEqual(start, try InboxTodayFixture.date("2026-11-10T22:00:00Z"))
    }

    func testSinceUTCFormat() throws {
        let since = InboxToday.sinceUTC(
            now: try InboxTodayFixture.date("2026-11-11T08:00:00Z"),
            calendar: try InboxTodayFixture.calendar("Europe/Kyiv")
        )
        XCTAssertEqual(since, "2026-11-10T22:00:00Z")
    }
}
