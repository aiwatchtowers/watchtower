import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Home's Today cards: which show, in what order, and their wording.
final class HomeTodayTests: XCTestCase {
    private let calendar = Calendar.current
    private var now: Date!
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        // A fixed morning keeps "later today" and "tomorrow" on their own days.
        now = try XCTUnwrap(calendar.date(bySettingHour: 8, minute: 0, second: 0, of: Date()))
        db = try TestDatabase.create()
    }

    // MARK: - Fixtures

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func at(hour: Int, minute: Int = 0, days: Int = 0) throws -> Date {
        let day = try XCTUnwrap(calendar.date(byAdding: .day, value: days, to: now))
        return try XCTUnwrap(calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day))
    }

    private func format(_ pattern: String, _ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = calendar.timeZone
        fmt.dateFormat = pattern
        return fmt.string(from: date)
    }

    private func action(
        _ id: Int64,
        status: String,
        reason: String = "Draft a reply",
        tool: String = "create_target",
        minutesAgo: Double
    ) -> AgentAction {
        AgentAction(row: Row([
            "id": id, "tool": tool, "reason": reason, "status": status,
            "created_at": iso(now.addingTimeInterval(-minutesAgo * 60))
        ]))
    }

    private func reminder(_ id: Int64, note: String = "Call back", minutesAgo: Double) -> Reminder {
        Reminder(row: Row([
            "id": id, "note": note, "status": "pending",
            "remind_at": iso(now.addingTimeInterval(-minutesAgo * 60))
        ]))
    }

    private func event(start: Date, end: Date? = nil, attendees: String = "[]") -> CalendarEvent {
        CalendarEvent(row: Row([
            "id": "evt-1", "title": "Design review", "start_time": iso(start),
            "end_time": iso(end ?? start.addingTimeInterval(1800)), "attendees": attendees
        ]))
    }

    private func briefing(attention: String = "[]", yourDay: String = "[]") -> Briefing {
        // swiftlint:disable:next force_try
        try! Briefing(row: Row([
            "id": 7, "user_id": "U001", "date": format("yyyy-MM-dd", now), "role": "engineer",
            "attention": attention, "your_day": yourDay, "what_happened": "[]", "team_pulse": "[]",
            "coaching": "[]", "model": "haiku", "input_tokens": 0, "output_tokens": 0, "cost_usd": 0.0,
            "prompt_version": 1, "created_at": iso(now)
        ]))
    }

    private func target(_ id: Int, _ text: String, status: String = "todo", due: String = "") -> Target {
        Target(row: Row(["id": id, "text": text, "status": status, "due_date": due]))
    }

    private func recap(status: String = "ready", acknowledged: Bool = false, from: Date) -> CatchUpRecap {
        var values: [String: (any DatabaseValueConvertible)?] = [
            "id": 3, "period_from": from.timeIntervalSince1970, "period_to": now.timeIntervalSince1970,
            "status": status, "tldr": "Two threads need you", "created_at": iso(now)
        ]
        if acknowledged { values["acknowledged_at"] = iso(now) }
        return CatchUpRecap(row: Row(values), now: now)
    }

    private func asks(_ specs: [(workbench: String, title: String, kind: String, session: Bool)]) throws
        -> WorkbenchAskRows {
        try db.write { d in
            var projects: [String: Int64] = [:]
            for (i, spec) in specs.enumerated() {
                let project = try projects[spec.workbench]
                    ?? TestDatabase.insertWorkbench(d, name: spec.workbench, folder: "/tmp/\(spec.workbench)")
                projects[spec.workbench] = project
                var session: Int64?
                if spec.session {
                    try d.execute(
                        sql: """
                            INSERT INTO terminal_sessions (project_id, kind, title, folder_path)
                            VALUES (?, 'shell', 'Session', ?)
                            """,
                        arguments: [project, "/tmp/\(spec.workbench)"])
                    session = d.lastInsertedRowID
                }
                try TestDatabase.insertOwnerAsk(d, projectID: project, sessionID: session, kind: spec.kind,
                                                title: spec.title,
                                                docPath: spec.kind == "review" ? "docs/spec.md" : "",
                                                createdAt: self.iso(self.now.addingTimeInterval(Double(i - 60) * 60)))
            }
            return try OwnerAskQueries.openAsksAllWorkbenches(d)
        }
    }

    private func fullData() throws -> HomeTodayData {
        var data = HomeTodayData()
        data.awaitingCount = 1
        data.actions = [action(1, status: "pending", minutesAgo: 5)]
        data.nextEvent = event(start: now.addingTimeInterval(3600))
        data.briefing = briefing(yourDay: #"[{"text":"Standup at 10"}]"#)
        data.targets = [target(1, "Ship the release", status: "in_progress")]
        data.asks = try asks([("acme", "Check the build", "check", false)])
        data.latestRecap = recap(from: now.addingTimeInterval(-86400))
        return data
    }

    private func cards(_ data: HomeTodayData, allowed: Set<TodayCardKind> = Set(TodayCardKind.allCases))
        -> [TodayCard] {
        HomeTodayBuilder.cards(data, allowed: allowed, now: now, calendar: calendar)
    }

    // MARK: - Which cards

    func testCardShowsOnlyWithContent() {
        var data = HomeTodayData()
        data.targets = [target(1, "Ship the release", status: "in_progress")]
        XCTAssertEqual(cards(data).map(\.kind), [.myTargets])
    }

    func testFixedOrder() throws {
        XCTAssertEqual(cards(try fullData()).map(\.kind), TodayCardKind.allCases)
    }

    func testAllowedFiltersCards() throws {
        var allowed = Set(TodayCardKind.allCases)
        allowed.remove(.sinceYouWereAway)
        let kinds = cards(try fullData(), allowed: allowed).map(\.kind)
        XCTAssertFalse(kinds.contains(.sinceYouWereAway))
        XCTAssertEqual(kinds.count, TodayCardKind.allCases.count - 1)
    }

    // MARK: - Waiting on you

    func testWaitingOnYouCountsLikeTheBadge() throws {
        var data = HomeTodayData()
        data.awaitingCount = 3
        // `awaitingOwner(limit: 3)` order: newest first.
        data.actions = [
            action(3, status: "failed", reason: "Post the summary", minutesAgo: 10),
            action(2, status: "pending", reason: "", tool: "create_target", minutesAgo: 20),
            action(1, status: "pending", reason: "Old", minutesAgo: 30)
        ]
        data.reminders = [reminder(1, note: "", minutesAgo: 25), reminder(2, note: "Call back", minutesAgo: 5)]
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.kind, .waitingOnYou)
        XCTAssertEqual(card.eyebrow, "WAITING ON YOU · 5")
        XCTAssertEqual(card.link, .inbox)
        XCTAssertEqual(card.items.map(\.chip), ["Reminder", "Failed", "Proposal"])
        XCTAssertEqual(card.items.map(\.title),
                       ["Call back", "Post the summary", ReactionToolCatalog.title(for: "create_target")])
        XCTAssertTrue(card.items.allSatisfy { $0.link == .inbox })
    }

    func testReminderWithoutNoteReadsReminder() throws {
        var data = HomeTodayData()
        data.reminders = [reminder(1, note: "", minutesAgo: 1)]
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "WAITING ON YOU · 1")
        XCTAssertEqual(card.items.map(\.title), ["Reminder"])
    }

    // MARK: - Agents waiting

    func testAsksAcrossAllWorkbenches() throws {
        var data = HomeTodayData()
        data.asks = try asks([("acme", "Review the spec", "review", true), ("beta", "Which way?", "question", false)])
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.kind, .agentsWaiting)
        XCTAssertEqual(card.eyebrow, "AGENTS WAITING · 2")
        XCTAssertEqual(card.link, .workbenches)
        XCTAssertEqual(card.items.map(\.chip), ["Review", "Question"])
        XCTAssertEqual(card.items.map(\.detail), ["acme", "beta"])
        let expected = data.asks.rows.map {
            HomeLink.workbench(.forAsk(projectID: $0.ask.projectID, sessionID: $0.ask.sessionID, askID: $0.ask.id))
        }
        XCTAssertEqual(card.items.map(\.link), expected)
        XCTAssertNotNil(data.asks.rows[0].ask.sessionID)
    }

    func testAgentsWaitingShowsThreeOldestAndCountsAll() throws {
        var data = HomeTodayData()
        data.asks = try asks((0..<4).map { ("acme", "Ask \($0)", "check", false) })
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "AGENTS WAITING · 4")
        XCTAssertEqual(card.items.map(\.title), ["Ask 0", "Ask 1", "Ask 2"])
    }

    // MARK: - Next meeting

    func testNextMeetingEyebrow() throws {
        XCTAssertEqual(HomeTodayBuilder.meetingEyebrow(start: now.addingTimeInterval(25 * 60), now: now,
                                                       calendar: calendar),
                       "NEXT MEETING · IN 25 MIN")
        XCTAssertEqual(HomeTodayBuilder.meetingEyebrow(start: try at(hour: 11), now: now, calendar: calendar),
                       "NEXT MEETING · 11:00")
        XCTAssertEqual(HomeTodayBuilder.meetingEyebrow(start: try at(hour: 9, days: 1), now: now, calendar: calendar),
                       "NEXT MEETING · TOMORROW 09:00")
    }

    func testNextMeetingBeyondHorizonHidden() {
        var data = HomeTodayData()
        data.nextEvent = event(start: now.addingTimeInterval(30 * 3600))
        XCTAssertTrue(cards(data).isEmpty)
    }

    func testNextMeetingLine() throws {
        let attendees = """
            [{"email":"a@example.com","display_name":"Colleague A","response_status":"","slack_user_id":""},
             {"email":"b@example.com","display_name":"Colleague B","response_status":"","slack_user_id":""},
             {"email":"c@example.com","display_name":"","response_status":"","slack_user_id":""}]
            """
        var data = HomeTodayData()
        data.nextEvent = event(start: try at(hour: 10), end: try at(hour: 10, minute: 30), attendees: attendees)
        data.nextEventHasPrep = true
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.kind, .nextMeeting)
        XCTAssertEqual(card.title, "Design review")
        XCTAssertEqual(card.body, "10:00–10:30 · Colleague A, Colleague B +1 · Prep ready")
        XCTAssertEqual(card.link, .calendarEvent(id: "evt-1"))
    }

    func testNextMeetingLineNamesEmailWhenBlankAndOmitsPrep() throws {
        let attendees = #"[{"email":"colleague.a@example.com","display_name":"","response_status":"","slack_user_id":""}]"#
        var data = HomeTodayData()
        data.nextEvent = event(start: try at(hour: 10), end: try at(hour: 11), attendees: attendees)
        XCTAssertEqual(try XCTUnwrap(cards(data).first).body, "10:00–11:00 · colleague.a")
    }

    // MARK: - Briefing

    func testBriefingSummaryIsFirstItemOfFirstNonEmptySection() throws {
        let filled = briefing(attention: "[]", yourDay: #"[{"text":"Standup at 10"}]"#)
        XCTAssertEqual(HomeTodayBuilder.briefingSummary(filled), "Standup at 10")
        var data = HomeTodayData()
        data.briefing = filled
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "BRIEFING")
        XCTAssertEqual(card.body, "Standup at 10")
        XCTAssertEqual(card.link, .briefing(id: 7))

        let empty = briefing()
        XCTAssertNil(HomeTodayBuilder.briefingSummary(empty))
        data.briefing = empty
        XCTAssertTrue(cards(data).isEmpty)
    }

    // MARK: - My targets

    func testTargetDetail() throws {
        let today = format("yyyy-MM-dd", now)
        let twoDaysAgo = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: now))
        let overdue = HomeTodayBuilder.targetDetail(
            target(1, "Late", due: format("yyyy-MM-dd", twoDaysAgo) + "T09:00"), today: today)
        XCTAssertEqual(overdue.0, "Overdue · " + format("MMM d", twoDaysAgo))
        XCTAssertEqual(overdue.1, .overdue)
        let dueToday = HomeTodayBuilder.targetDetail(target(2, "Today", due: today), today: today)
        XCTAssertEqual(dueToday.0, "Due today")
        XCTAssertEqual(dueToday.1, .dueToday)
        let dueAtTime = HomeTodayBuilder.targetDetail(target(3, "At three", due: today + "T15:00"), today: today)
        XCTAssertEqual(dueAtTime.0, "Due 15:00")
        XCTAssertEqual(dueAtTime.1, .dueToday)
        let inProgress = HomeTodayBuilder.targetDetail(target(4, "Going", status: "in_progress"), today: today)
        XCTAssertEqual(inProgress.0, "In progress")
        XCTAssertEqual(inProgress.1, .inProgress)
    }

    func testMyTargetsCardLinks() throws {
        var data = HomeTodayData()
        data.targets = [target(4, "Going", status: "in_progress")]
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "MY TARGETS")
        XCTAssertEqual(card.link, .targets)
        XCTAssertEqual(card.items, [TodayItem(chip: nil, title: "Going", detail: "In progress", tone: .inProgress,
                                              link: .target(id: 4))])
    }

    // MARK: - Since you were away

    func testRecapCardNeedsReadyUnacknowledged() throws {
        let from = try at(hour: 18, minute: 30, days: -1)
        var data = HomeTodayData()
        data.latestRecap = recap(status: "building", from: from)
        XCTAssertTrue(cards(data).isEmpty)
        data.latestRecap = recap(acknowledged: true, from: from)
        XCTAssertTrue(cards(data).isEmpty)
        data.latestRecap = recap(from: from)
        let card = try XCTUnwrap(cards(data).first)
        XCTAssertEqual(card.eyebrow, "SINCE YOU WERE AWAY · SINCE " + format("EEE", from).uppercased() + " 18:30")
        XCTAssertEqual(card.body, "Two threads need you")
        XCTAssertEqual(card.link, .catchUp)
    }

    // MARK: - Snapshot

    private func snapshot(_ zone: GettingReadyZone, today: [TodayCard] = [], failed: Bool = false) -> HomeSnapshot {
        HomeSnapshot(gettingReady: zone, firstSync: nil, today: today, todayReadFailed: failed)
    }

    func testEmptyDataIsNothingNeedsYou() {
        let today = cards(HomeTodayData())
        XCTAssertTrue(today.isEmpty)
        XCTAssertTrue(snapshot(.hidden, today: today).nothingNeedsYou)
    }

    func testAllReadyZoneStillNothingNeedsYou() {
        XCTAssertTrue(snapshot(.allReady).nothingNeedsYou)
    }

    func testShownZoneIsNotNothingNeedsYou() {
        XCTAssertFalse(snapshot(.shown(cards: [], sourceRows: [])).nothingNeedsYou)
    }

    func testFailedReadIsNotNothingNeedsYou() {
        XCTAssertFalse(snapshot(.hidden, failed: true).nothingNeedsYou)
    }
}
