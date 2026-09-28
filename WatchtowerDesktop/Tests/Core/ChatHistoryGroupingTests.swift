import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatHistoryGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private func conversations(_ ages: [(String, TimeInterval, Bool)]) throws -> [ChatConversation] {
        let db = try TestDatabase.create()
        return try db.write { d in
            for (title, age, pinned) in ages {
                try TestDatabase.insertChatConversation(
                    d, title: title, updatedAt: now.addingTimeInterval(-age).timeIntervalSince1970, pinned: pinned)
            }
            return try ChatConversationQueries.fetchAll(d)
        }
    }

    func testBucketsByDayWithPinnedFirst() throws {
        let day: TimeInterval = 86_400
        let convs = try conversations([
            ("today", 3600, false), ("yesterday", day, false), ("week", 3 * day, false),
            ("month", 20 * day, false), ("old", 60 * day, false), ("pinned-old", 90 * day, true)
        ])
        let sections = ChatHistoryGrouping.group(convs, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .today, .yesterday, .previous7Days, .previous30Days, .older])
        XCTAssertEqual(sections.map { $0.conversations.map(\.title) },
                       [["pinned-old"], ["today"], ["yesterday"], ["week"], ["month"], ["old"]])
        XCTAssertEqual(sections.map(\.kind.title),
                       ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"])
    }

    func testEmptyInputHasNoSections() {
        XCTAssertTrue(ChatHistoryGrouping.group([], now: now, calendar: calendar).isEmpty)
    }

    func testNewestFirstInsideASection() throws {
        let convs = try conversations([("older", 7200, false), ("newer", 60, false)])
        let today = try XCTUnwrap(ChatHistoryGrouping.group(convs, now: now, calendar: calendar).first)
        XCTAssertEqual(today.conversations.map(\.title), ["newer", "older"])
    }
}
