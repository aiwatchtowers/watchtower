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
        limit: Int = HomeFeedBuilder.waitingLimit,
        hidden: Set<FeedRef> = []
    ) -> HomeFeed {
        HomeFeedBuilder.feed(data, now: override ?? now, calendar: calendar, limit: limit, hidden: hidden)
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

    private func output(_ id: Int64, title: String = "Two threads need you", minutesAgo: Double = 15) -> AutomationOutputCard {
        AutomationOutputCard(
            id: id, automationID: 1, automationName: "Mail summary", runID: 1, title: title,
            body: "Ann and Bo wait on a reply.", priority: "medium",
            createdAt: now.addingTimeInterval(-minutesAgo * 60))
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
        data.outputs = [output(6)]
        let feed = build(data)
        XCTAssertEqual(feed.waiting.map(\.id),
                       [.inbox(2), .proposal(5), .output(6), .reminder(3), .target(4), .inbox(1)])
    }

    /// An automation's inbox output: its title over the body, the
    /// automation's name as the place, Done / Hide, its run on a click.
    func testAutomationOutputRow() throws {
        var data = HomeFeedData()
        data.outputs = [output(6), output(7, title: "", minutesAgo: 30)]
        let rows = build(data).waiting
        XCTAssertEqual(rows.map(\.id), [.output(6), .output(7)])
        let row = rows[0]
        XCTAssertEqual(row.kind, .automation)
        XCTAssertEqual(row.chip, "Automation")
        XCTAssertEqual(row.who, "Two threads need you")
        XCTAssertEqual(row.whereText, "Mail summary")
        XCTAssertEqual(row.text, "Ann and Bo wait on a reply.")
        XCTAssertEqual(row.actions, [.done, .hide])
        XCTAssertEqual(row.link, .automationRun(automationID: 1, runID: 1))
        XCTAssertFalse(row.read)
        XCTAssertEqual(rows[1].who, "Automation output")
        XCTAssertTrue(FeedRef.output(6).hasActions)
    }

    func testCapAtSevenAndNMore() {
        var data = HomeFeedData()
        data.inbox = (1...10).map { inbox($0, minutesAgo: Double($0)) }
        let capped = build(data)
        XCTAssertEqual(capped.waiting.count, 7)
        XCTAssertEqual(capped.hiddenWaiting, 3)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(capped), 3, "never more than remain")
        let all = build(data, limit: HomeFeedBuilder.nextLimit(after: HomeFeedBuilder.waitingLimit))
        XCTAssertEqual(all.waiting.count, 10)
        XCTAssertEqual(all.hiddenWaiting, 0)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(all), 0)
    }

    private func pagedFeed(rows count: Int, limit: Int, hidden: Set<FeedRef> = []) -> HomeFeed {
        var data = HomeFeedData()
        data.inbox = (1...count).map { inbox($0, minutesAgo: Double($0)) }
        return build(data, limit: limit, hidden: hidden)
    }

    /// The first expand goes from seven to 50, each later page adds 50.
    func testNextLimitPages() {
        XCTAssertEqual(HomeFeedBuilder.expandedLimit, 50)
        XCTAssertEqual(HomeFeedBuilder.nextLimit(after: 7), 50)
        XCTAssertEqual(HomeFeedBuilder.nextLimit(after: 50), 100)
        XCTAssertEqual(HomeFeedBuilder.nextLimit(after: 100), 150)
    }

    /// 120 rows: seven, then 50, 100 and the last partial page of 20; each
    /// "N more" says what the next page really adds.
    func testPagesThroughABacklog() {
        let collapsed = pagedFeed(rows: 120, limit: 7)
        XCTAssertEqual(collapsed.waiting.count, 7)
        XCTAssertEqual(collapsed.hiddenWaiting, 113)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(collapsed), 43, "N more never overpromises")

        let first = pagedFeed(rows: 120, limit: 50)
        XCTAssertEqual(first.waiting.map(\.id), (1...50).map { FeedRef.inbox($0) }, "newest first")
        XCTAssertEqual(first.hiddenWaiting, 70)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(first), 50)

        let second = pagedFeed(rows: 120, limit: 100)
        XCTAssertEqual(second.waiting.count, 100)
        XCTAssertEqual(second.waiting.last?.id, .inbox(100))
        XCTAssertEqual(second.hiddenWaiting, 20)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(second), 20, "the last page is partial")

        let last = pagedFeed(rows: 120, limit: 150)
        XCTAssertEqual(last.waiting.count, 120)
        XCTAssertEqual(last.hiddenWaiting, 0)
    }

    func testPageBoundaries() {
        let exact = pagedFeed(rows: 50, limit: 50)
        XCTAssertEqual(exact.waiting.count, 50)
        XCTAssertEqual(exact.hiddenWaiting, 0, "exactly a page: nothing left")
        let oneOver = pagedFeed(rows: 51, limit: 50)
        XCTAssertEqual(oneOver.waiting.count, 50)
        XCTAssertEqual(oneOver.hiddenWaiting, 1)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(oneOver), 1)
        XCTAssertEqual(HomeFeedBuilder.nextPageCount(pagedFeed(rows: 8, limit: 7)), 1)
        XCTAssertEqual(pagedFeed(rows: 7, limit: 7).hiddenWaiting, 0)
    }

    /// Rows just Done / Hidden leave before the limit, so the next row is
    /// pulled into the page.
    func testHiddenRefsPullTheNextRowIn() {
        let feed = pagedFeed(rows: 53, limit: 50, hidden: [.inbox(1), .inbox(52)])
        XCTAssertEqual(feed.waiting.count, 50)
        XCTAssertEqual(feed.waiting.first?.id, .inbox(2))
        XCTAssertEqual(feed.waiting.last?.id, .inbox(51), "the next row moved up into the page")
        XCTAssertEqual(feed.hiddenWaiting, 1)
    }

    /// Kinds sort first, so a Slack backlog fills the first page; targets
    /// and email are on a later one, never cut off.
    func testTailKindsReachableOnALaterPage() {
        var data = HomeFeedData()
        data.inbox = (1...60).map { inbox($0, minutesAgo: Double($0)) }
            + [inbox(100, trigger: "email_received", minutesAgo: 1)]
        data.targets = [target(200, due: "2026-10-19")]
        let first = build(data, limit: 50)
        XCTAssertFalse(first.waiting.contains { $0.kind == .target || $0.kind == .email })
        XCTAssertEqual(first.hiddenWaiting, 12)
        let second = build(data, limit: HomeFeedBuilder.nextLimit(after: 50))
        XCTAssertEqual(second.hiddenWaiting, 0)
        XCTAssertEqual(second.waiting.suffix(2).map(\.id), [.target(200), .inbox(100)])
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
        XCTAssertEqual(rows[1].link, .catchUp)
        XCTAssertEqual(rows[2].link, .target(id: 4))
    }

    /// An inbox row with no permalink it can open (empty, or no scheme)
    /// opens Catch-Up instead (final review #717).
    func testLinearRowSharesTheTrackerKindWithItsOwnChip() {
        var data = HomeFeedData()
        data.inbox = [
            inbox(1, trigger: "linear_assigned", minutesAgo: 1, who: "ACME-9", whereText: "assigned to you"),
            inbox(2, trigger: "jira_assigned", minutesAgo: 2, who: "ACME-7", whereText: "assigned to you")
        ]
        let rows = build(data).waiting
        XCTAssertEqual(rows.map(\.chip), ["Linear", "Jira"])
        XCTAssertEqual(rows.map(\.kind), [.jira, .jira])
    }

    func testInboxRowWithoutAPermalinkOpensCatchUp() {
        var data = HomeFeedData()
        data.inbox = [inbox(1, minutesAgo: 1), inbox(2, minutesAgo: 2, permalink: "not a link")]
        XCTAssertEqual(build(data).waiting.map(\.link), [.catchUp, .catchUp])
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
