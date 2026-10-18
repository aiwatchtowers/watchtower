import XCTest
import GRDB
@testable import WatchtowerCore

/// Home's feed: which rows wait above NOW, in what order, and what follows.
final class HomeFeedBuilderTests: XCTestCase {
    private var calendar = Calendar(identifier: .gregorian)
    /// Tuesday 2026-10-20, 10:40.
    private var now: Date!

    override func setUpWithError() throws {
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        now = try at(day: 20, hour: 10, minute: 40)
    }

    // MARK: - Fixtures

    private func at(day: Int, hour: Int, minute: Int = 0, month: Int = 10) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func build(
        _ data: HomeFeedData,
        now override: Date? = nil,
        expanded: Bool = false,
        hidden: Set<FeedRef> = []
    ) -> HomeFeed {
        HomeFeedBuilder.feed(data, now: override ?? now, calendar: calendar, expanded: expanded, hidden: hidden)
    }

    private func inbox(
        _ id: Int,
        trigger: String = "mention",
        minutesAgo: Double,
        read: Bool = false,
        who: String = "Ann",
        whereText: String? = "#eng",
        permalink: String = ""
    ) -> HomeFeedInboxRow {
        let stamp = now.addingTimeInterval(-minutesAgo * 60)
        let item = InboxItem(row: Row([
            "id": id, "trigger_type": trigger, "snippet": "Text \(id)", "permalink": permalink,
            "read_at": read ? iso(stamp) : "", "created_at": iso(stamp)
        ]))
        return HomeFeedInboxRow(item: item, stamp: stamp, who: who, whereText: whereText)
    }

    private func reminder(_ id: Int64, at date: Date) -> Reminder {
        Reminder(row: Row(["id": id, "note": "Call back", "status": "pending", "remind_at": iso(date)]))
    }

    private func proposal(_ id: Int64, status: String = "pending", reason: String = "Draft a reply") -> AgentAction {
        AgentAction(row: Row([
            "id": id, "tool": "create_target", "reason": reason, "status": status,
            "created_at": iso(now.addingTimeInterval(-600))
        ]))
    }

    private func target(_ id: Int, due: String) -> Target {
        Target(row: Row(["id": id, "text": "Ship it", "status": "todo", "due_date": due]))
    }

    private func event(_ id: String, start: Date, minutes: Double = 30) -> CalendarEvent {
        CalendarEvent(row: Row([
            "id": id, "title": "Meeting \(id)", "start_time": iso(start),
            "end_time": iso(start.addingTimeInterval(minutes * 60)), "attendees": "[]"
        ]))
    }

    // MARK: - Above NOW

    func testKindOrderThenNewest() throws {
        var data = HomeFeedData()
        data.inbox = [
            inbox(1, trigger: "email_received", minutesAgo: 5),
            inbox(2, minutesAgo: 120)
        ]
        data.dueReminders = [reminder(3, at: now.addingTimeInterval(-300))]
        data.targets = [target(4, due: "2026-10-19")]
        data.proposals = [proposal(5)]
        let feed = build(data)
        XCTAssertEqual(feed.waiting.map(\.id), [.inbox(2), .proposal(5), .reminder(3), .target(4), .inbox(1)])
    }

    func testCapAtSevenAndNMore() {
        var data = HomeFeedData()
        data.inbox = (1...10).map { inbox($0, minutesAgo: Double($0)) }
        let capped = build(data)
        XCTAssertEqual(capped.waiting.count, 7)
        XCTAssertEqual(capped.hiddenWaiting, 3)
        let all = build(data, expanded: true)
        XCTAssertEqual(all.waiting.count, 10)
        XCTAssertEqual(all.hiddenWaiting, 0)
    }

    func testHiddenRefsLeave() {
        var data = HomeFeedData()
        data.inbox = [inbox(3, minutesAgo: 1), inbox(4, minutesAgo: 2)]
        XCTAssertEqual(build(data, hidden: [.inbox(4)]).waiting.map(\.id), [.inbox(3)])
    }

    func testReadRowIsKeptAndMarked() throws {
        var data = HomeFeedData()
        data.inbox = [inbox(1, minutesAgo: 5, read: true)]
        let row = try XCTUnwrap(build(data).waiting.first)
        XCTAssertTrue(row.read)
    }

    func testRowContentMatchesTheMockup() throws {
        var data = HomeFeedData()
        data.proposals = [proposal(5), proposal(6, reason: "")]
        data.dueReminders = [reminder(3, at: now.addingTimeInterval(-300))]
        data.targets = [target(4, due: "2026-10-19")]
        let rows = build(data).waiting
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let first = try XCTUnwrap(byID[.proposal(5)])
        XCTAssertEqual(first.who, "Draft a reply")
        XCTAssertEqual(first.text, "Drafted by the assistant \u{00B7} review in Inbox")
        XCTAssertEqual(try XCTUnwrap(byID[.proposal(6)]).who, ReactionToolCatalog.title(for: "create_target"))
        let reminderRow = try XCTUnwrap(byID[.reminder(3)])
        XCTAssertEqual(reminderRow.who, "Call back")
        XCTAssertEqual(reminderRow.text, "Reminder")
        let targetRow = try XCTUnwrap(byID[.target(4)])
        XCTAssertEqual(targetRow.who, "Ship it")
        XCTAssertEqual(targetRow.text, "My target")
    }

    func testNewestFirstWithinAKind() {
        var data = HomeFeedData()
        data.inbox = [inbox(1, minutesAgo: 60), inbox(2, minutesAgo: 5)]
        data.dueReminders = [reminder(10, at: now.addingTimeInterval(-3600)), reminder(11, at: now.addingTimeInterval(-60))]
        data.targets = [target(20, due: "2026-10-18"), target(21, due: "2026-10-19")]
        let ids = build(data).waiting.map(\.id)
        XCTAssertEqual(ids, [.inbox(2), .inbox(1), .reminder(11), .reminder(10), .target(21), .target(20)])
    }

    func testHiddenRefsLeaveBelowNowToo() throws {
        var data = HomeFeedData()
        data.targets = [target(4, due: "2026-10-20T16:00")]
        data.laterReminders = [reminder(9, at: try at(day: 20, hour: 14))]
        XCTAssertTrue(build(data, hidden: [.target(4), .reminder(9)]).laterToday.isEmpty)
    }

    func testMeetingUnderAMinuteSaysNow() throws {
        var data = HomeFeedData()
        data.events = [event("a", start: now.addingTimeInterval(30))]
        XCTAssertEqual(build(data).laterToday.first?.chip, "now")
    }

    func testProposalHasNoActions() throws {
        var data = HomeFeedData()
        data.proposals = [proposal(5, status: "failed")]
        let row = try XCTUnwrap(build(data).waiting.first)
        XCTAssertTrue(row.actions.isEmpty)
        XCTAssertEqual(row.chip, "Failed")
    }

    func testUnresolvedSenderShowsThePlace() throws {
        var data = HomeFeedData()
        data.inbox = [inbox(1, minutesAgo: 1, who: "", whereText: "#eng"), inbox(2, minutesAgo: 2, who: "", whereText: nil)]
        let rows = build(data).waiting
        XCTAssertEqual(rows[0].who, "#eng")
        XCTAssertNil(rows[0].whereText)
        XCTAssertEqual(rows[1].who, "Slack")
    }

    func testLinks() throws {
        var data = HomeFeedData()
        data.inbox = [inbox(1, minutesAgo: 1, permalink: "https://example.com/p/1"), inbox(2, minutesAgo: 2)]
        data.targets = [target(4, due: "2026-10-19")]
        let rows = build(data).waiting
        XCTAssertEqual(rows[0].link, .permalink(try XCTUnwrap(URL(string: "https://example.com/p/1"))))
        XCTAssertEqual(rows[1].link, .inbox)
        XCTAssertEqual(rows[2].link, .target(id: 4))
    }

    // MARK: - Below NOW

    func testOngoingMeetingSitsOnNow() throws {
        var data = HomeFeedData()
        data.events = [event("a", start: try at(day: 20, hour: 10), minutes: 60)]
        let feed = build(data)
        XCTAssertEqual(feed.ongoing?.chip, "until 11:00")
        XCTAssertTrue(feed.laterToday.isEmpty)
        XCTAssertEqual(feed.nowLabel, "10:40")
    }

    func testNextMeetingInMinutes() throws {
        var data = HomeFeedData()
        data.events = [event("a", start: try at(day: 20, hour: 11)), event("b", start: try at(day: 20, hour: 15))]
        let feed = build(data)
        XCTAssertTrue(try XCTUnwrap(feed.laterToday.first).isNext)
        XCTAssertEqual(feed.laterToday.first?.chip, "in 20 min")
        XCTAssertFalse(feed.laterToday[1].isNext)
        XCTAssertEqual(feed.laterToday[1].chip, "Meeting")
    }

    func testTimedTargetAndLaterReminderBelowNow() throws {
        var data = HomeFeedData()
        data.targets = [target(4, due: "2026-10-20T16:00")]
        data.laterReminders = [reminder(9, at: try at(day: 20, hour: 14))]
        let feed = build(data)
        XCTAssertTrue(feed.waiting.isEmpty)
        XCTAssertEqual(feed.laterToday.map(\.chip), ["Reminder", "Due"])
    }

    func testTomorrowNeverUnderToday() throws {
        var data = HomeFeedData()
        data.events = [event("a", start: try at(day: 26, hour: 9, minute: 30))]
        let feed = build(data, now: try at(day: 25, hour: 21, minute: 10))
        XCTAssertTrue(feed.laterToday.isEmpty)
        XCTAssertEqual(feed.nextDay?.title, "Tomorrow")
    }

    func testFridayEveningShowsMonday() throws {
        let friday = try at(day: 23, hour: 20)
        var data = HomeFeedData()
        data.events = [event("a", start: try at(day: 26, hour: 9, minute: 30))]
        XCTAssertEqual(build(data, now: friday).nextDay?.title, "Monday")
        data.events = [event("b", start: try at(day: 29, hour: 9))]
        XCTAssertNil(build(data, now: friday).nextDay)
    }

    func testNextDayMeetingsOnlyMaxThree() throws {
        var data = HomeFeedData()
        data.events = (0..<5).map { event("e\($0)", start: (try? at(day: 21, hour: 9 + $0)) ?? now) }
        data.laterReminders = [reminder(1, at: try at(day: 21, hour: 8))]
        let day = try XCTUnwrap(build(data).nextDay)
        XCTAssertEqual(day.events.count, 3)
        XCTAssertTrue(day.events.allSatisfy { if case .event = $0.id { true } else { false } })
    }

    func testMidnightRollsTheNextDayIntoToday() throws {
        var data = HomeFeedData()
        data.events = [event("a", start: try at(day: 21, hour: 9, minute: 30))]
        let before = build(data, now: try at(day: 20, hour: 23, minute: 59))
        XCTAssertEqual(before.nextDay?.events.count, 1)
        XCTAssertTrue(before.laterToday.isEmpty)
        let after = build(data, now: try at(day: 21, hour: 0, minute: 1))
        XCTAssertNil(after.nextDay)
        XCTAssertEqual(after.laterToday.count, 1)
    }

    func testFailedSourceIsNeverAllClear() {
        var data = HomeFeedData()
        data.failed = [.inbox]
        let feed = build(data)
        XCTAssertEqual(feed.failed, [.inbox])
        XCTAssertTrue(feed.waiting.isEmpty)
    }
}
