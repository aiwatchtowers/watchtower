import Foundation
import XCTest

/// The "from today" fixture shared with Go
/// (`internal/inbox/testdata/from_today.json`) and its time helpers.
enum InboxTodayFixture {
    struct Case: Decodable {
        let name: String
        let now: String
        let tz: String
        let createdAt: String
        /// "" or null = none.
        let mentionedAt: String?
        let expected: Bool

        enum CodingKeys: String, CodingKey {
            case name, now, tz, expected
            case createdAt = "created_at"
            case mentionedAt = "mentioned_at"
        }
    }

    private struct File: Decodable {
        let cases: [Case]
    }

    static func cases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/inbox/testdata/from_today.json")
        return try JSONDecoder().decode(File.self, from: Data(contentsOf: url)).cases
    }

    static func date(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text), "bad time \(text)", file: file, line: line)
    }

    static func calendar(_ tz: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: tz), "unknown zone \(tz)")
        return calendar
    }
}
