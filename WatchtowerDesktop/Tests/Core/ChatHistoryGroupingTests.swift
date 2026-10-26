import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatHistoryGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let day: TimeInterval = 86_400
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

    func testPinnedRecentOlder() throws {
        let convs = try conversations([
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
        let sevenBack = startOfToday.addingTimeInterval(-7 * day + 1)   // the first second of 7 days back
        let eightBack = startOfToday.addingTimeInterval(-7 * day - 1)   // the last second of 8 days back
        let convs = try conversations([
            ("seven", now.timeIntervalSince(sevenBack), false), ("eight", now.timeIntervalSince(eightBack), false)
        ])
        let seven = try XCTUnwrap(convs.first { $0.title == "seven" })
        let eight = try XCTUnwrap(convs.first { $0.title == "eight" })
        XCTAssertEqual(ChatHistoryGrouping.kind(of: seven, now: now, calendar: calendar), .recent)
        XCTAssertEqual(ChatHistoryGrouping.kind(of: eight, now: now, calendar: calendar), .older)
    }

    func testEmptyInputHasNoSections() {
        XCTAssertTrue(ChatHistoryGrouping.group([ChatConversation](), now: now, calendar: calendar).isEmpty)
    }

    func testArchivedSkipped() throws {
        let db = try TestDatabase.create()
        let convs = try db.write { d in
            let id = try TestDatabase.insertChatConversation(d, title: "gone", updatedAt: now.timeIntervalSince1970)
            try d.execute(sql: "UPDATE chat_conversations SET archived_at = 1 WHERE id = ?", arguments: [id])
            return try ChatConversationQueries.fetchAll(d)
        }
        XCTAssertTrue(ChatHistoryGrouping.group(convs, now: now, calendar: calendar).isEmpty)
    }

    func testNewestFirstInsideASection() throws {
        let convs = try conversations([("older", 7200, false), ("newer", 60, false)])
        let recent = try XCTUnwrap(ChatHistoryGrouping.group(convs, now: now, calendar: calendar).first)
        XCTAssertEqual(recent.items.map(\.title), ["newer", "older"])
    }

    func testGroupsPanelRows() throws {
        let convs = try conversations([("pinned", 50 * day, true), ("fresh", 60, false)])
        let rows = convs.map {
            ChatPanelRow(conversation: $0, lastAnswerAt: nil, lastAnswerPreview: "",
                         pendingApprovals: 0, pendingTool: nil, projectName: nil)
        }
        let sections = ChatHistoryGrouping.group(rows, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .recent])
        XCTAssertEqual(sections.map { $0.items.map(\.conversation.title) }, [["pinned"], ["fresh"]])
    }
}
