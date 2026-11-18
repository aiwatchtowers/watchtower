import ChatWire
import XCTest
@testable import WatchtowerCore

/// The Chats panel's Pinned / Recent / older sections over the engine's list.
final class ChatHistoryGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private func conversations(_ ages: [(String, TimeInterval, Bool)]) -> [ChatList.Conversation] {
        ages.enumerated().map { index, row in
            ChatList.Conversation(id: Int64(index + 1), title: row.0, pinned: row.2,
                                  updatedAt: now.addingTimeInterval(-row.1), state: .read)
        }
    }

    func testPinnedRecentOlder() {
        let convs = conversations([
            ("today", 3600, false), ("yesterday", day, false), ("week", 6 * day, false),
            ("month", 20 * day, false), ("old", 60 * day, false), ("pinned-old", 90 * day, true),
            ("pinned-new", 60, true)
        ])
        let sections = ChatHistoryGrouping.group(convs, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .recent, .older])
        XCTAssertEqual(sections.map { $0.items.map(\.title) },
                       [["pinned-new", "pinned-old"], ["today", "yesterday", "week"], ["month", "old"]])
        XCTAssertEqual(sections.map(\.kind.title), ["Pinned", "Recent", "Older"])
    }

    /// The boundary counts calendar days from the start of today: seven days
    /// back is still recent, eight is older, whatever the hour.
    func testSevenDayBoundaryOnStartOfDay() throws {
        let startOfToday = calendar.startOfDay(for: now)
        let sevenBack = startOfToday.addingTimeInterval(-7 * day + 1)
        let eightBack = startOfToday.addingTimeInterval(-7 * day - 1)
        let convs = conversations([
            ("seven", now.timeIntervalSince(sevenBack), false), ("eight", now.timeIntervalSince(eightBack), false)
        ])
        let seven = try XCTUnwrap(convs.first { $0.title == "seven" })
        let eight = try XCTUnwrap(convs.first { $0.title == "eight" })
        XCTAssertEqual(ChatHistoryGrouping.kind(of: seven, now: now, calendar: calendar), .recent)
        XCTAssertEqual(ChatHistoryGrouping.kind(of: eight, now: now, calendar: calendar), .older)
    }

    func testEmptyInputHasNoSections() {
        XCTAssertTrue(ChatHistoryGrouping.group([], now: now, calendar: calendar).isEmpty)
    }

    func testNewestFirstInsideASection() throws {
        let convs = conversations([("older", 7200, false), ("newer", 60, false)])
        let recent = try XCTUnwrap(ChatHistoryGrouping.group(convs, now: now, calendar: calendar).first)
        XCTAssertEqual(recent.items.map(\.title), ["newer", "older"])
    }
}
