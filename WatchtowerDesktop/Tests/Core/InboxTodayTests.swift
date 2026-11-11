import Foundation
import XCTest
@testable import WatchtowerCore

/// The Inbox "from today" rule over the fixture shared with Go
/// (`internal/inbox/testdata/from_today.json`).
final class InboxTodayTests: XCTestCase {
    private struct Fixture: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable {
        let name: String
        let now: String
        let tz: String
        let createdAt: String
        let mentionedAt: String?
        let expected: Bool

        enum CodingKeys: String, CodingKey {
            case name, now, tz, expected
            case createdAt = "created_at"
            case mentionedAt = "mentioned_at"
        }
    }

    private static func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/inbox/testdata/from_today.json")
    }

    private static func date(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), "bad time \(text)", file: file, line: line)
    }

    private static func calendar(_ tz: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: tz), "unknown zone \(tz)")
        return calendar
    }

    func testFixtureCases() throws {
        let data = try Data(contentsOf: Self.fixtureURL())
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 9)
        for item in fixture.cases {
            let mentioned = item.mentionedAt.flatMap { $0.isEmpty ? nil : $0 }
            let got = InboxToday.isFromToday(
                createdAt: try Self.date(item.createdAt),
                mentionedAt: try mentioned.map { try Self.date($0) },
                now: try Self.date(item.now),
                calendar: try Self.calendar(item.tz)
            )
            XCTAssertEqual(got, item.expected, item.name)
        }
    }

    func testStartOfTodayIsLocalMidnight() throws {
        let start = InboxToday.startOfToday(
            now: try Self.date("2026-11-11T08:00:00Z"),
            calendar: try Self.calendar("Europe/Kyiv")
        )
        XCTAssertEqual(start, try Self.date("2026-11-10T22:00:00Z"))
    }

    func testSinceUTCFormat() throws {
        let since = InboxToday.sinceUTC(
            now: try Self.date("2026-11-11T08:00:00Z"),
            calendar: try Self.calendar("Europe/Kyiv")
        )
        XCTAssertEqual(since, "2026-11-10T22:00:00Z")
    }
}
