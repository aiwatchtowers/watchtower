import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The reads behind Home's feed: the inbox window and its triggers, the
/// owner's targets, the calendar and the reminders, each source on its own.
final class HomeFeedQueriesTests: XCTestCase {
    private var db: DatabaseQueue!
    private let calendar = Calendar.current
    /// Noon today, so "today" and "72 hours ago" never straddle a day edge.
    private var now: Date {
        calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    }

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func hoursAgo(_ hours: Double) -> String { iso(now.addingTimeInterval(-hours * 3600)) }

    private var ticks = 0

    /// An inbox row with explicit stamps (the shared fixture takes none).
    @discardableResult
    private func insertItem(
        _ d: Database,
        trigger: String = "mention",
        createdAt: String? = nil,
        mentionedAt: String = "",
        status: String = "pending",
        itemClass: String = "actionable",
        snoozeUntil: String = "",
        channelID: String = "C001",
        sender: String = "U002",
        snippet: String = "Can you look?",
        readAt: String? = nil
    ) throws -> Int64 {
        ticks += 1
        let id = try TestDatabase.insertInboxItem(
            d, channelID: channelID, messageTS: "1700000000.\(String(format: "%06d", ticks))",
            senderUserID: sender, triggerType: trigger, snippet: snippet, status: status,
            snoozeUntil: snoozeUntil, readAt: readAt, itemClass: itemClass
        )
        try d.execute(
            sql: "UPDATE inbox_items SET created_at = ?, mentioned_at = ? WHERE id = ?",
            arguments: [createdAt ?? hoursAgo(1), mentionedAt, id]
        )
        return id
    }

    @discardableResult
    private func insertTarget(
        _ d: Database, _ text: String, status: String = "todo", dueDate: String = "", projectID: Int64? = nil
    ) throws -> Int64 {
        let today = HomeFeedBuilder.dayString(now, calendar: calendar)
        try d.execute(
            sql: """
                INSERT INTO targets (text, level, period_start, period_end, status, ownership, due_date,
                    source_type, project_id)
                VALUES (?, 'day', ?, ?, ?, 'mine', ?, 'manual', ?)
                """,
            arguments: [text, today, today, status, dueDate, projectID]
        )
        return d.lastInsertedRowID
    }

    private func dayString(_ offset: Int) throws -> String {
        let date = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now))
        return HomeFeedBuilder.dayString(date, calendar: calendar)
    }

    private func read() throws -> HomeFeedData {
        try db.read { HomeFeedQueries.read($0, now: self.now, calendar: self.calendar) }
    }

    // MARK: - Inbox

    func testInboxWindowIs72Hours() throws {
        try db.write { d in
            try self.insertItem(d, createdAt: self.hoursAgo(71))
            try self.insertItem(d, createdAt: self.hoursAgo(73))
        }
        let data = try read()
        XCTAssertEqual(data.inbox.count, 1)
        XCTAssertEqual(data.inbox.first.map { iso($0.stamp) }, hoursAgo(71))
    }

    func testOnlyActionablePendingFeedTriggers() throws {
        try db.write { d in
            try self.insertItem(d, trigger: "mention")
            try self.insertItem(d, trigger: "email_cc")
            try self.insertItem(d, trigger: "briefing_ready")
            try self.insertItem(d, trigger: "calendar_invite")
            try self.insertItem(d, trigger: "mention", status: "resolved")
            try self.insertItem(d, trigger: "mention", itemClass: "ambient")
            try self.insertItem(d, trigger: "dm", snoozeUntil: self.iso(self.now.addingTimeInterval(86400)))
        }
        let data = try read()
        XCTAssertEqual(data.inbox.map(\.item.triggerType), ["mention"])
    }

    /// A snooze that has elapsed no longer hides the row.
    /// An archived item is gone from Home, as from the briefing's
    /// `ListActionableOpen`.
    func testArchivedItemIsLeftOut() throws {
        try db.write { d in
            try self.insertItem(d, snippet: "kept")
            let archived = try self.insertItem(d, snippet: "archived")
            try d.execute(sql: "UPDATE inbox_items SET archived_at = ? WHERE id = ?",
                          arguments: [self.hoursAgo(0.5), archived])
        }
        XCTAssertEqual(try read().inbox.map(\.item.snippet), ["kept"])
    }

    func testElapsedSnoozeIsShown() throws {
        try db.write { d in
            try self.insertItem(d, trigger: "dm", snoozeUntil: self.hoursAgo(1))
        }
        XCTAssertEqual(try read().inbox.count, 1)
    }

    func testMentionedAtCountsAsTheStamp() throws {
        try db.write { d in
            try self.insertItem(d, createdAt: self.hoursAgo(5 * 24), mentionedAt: self.hoursAgo(1))
        }
        let data = try read()
        XCTAssertEqual(data.inbox.count, 1)
        XCTAssertEqual(data.inbox.first.map { iso($0.stamp) }, hoursAgo(1))
    }

    func testOldBacklogStaysOutAndCountIsBounded() throws {
        try db.write { d in
            for _ in 0..<500 {
                try self.insertItem(d, trigger: "email_received", createdAt: self.hoursAgo(240))
            }
            for _ in 0..<3 {
                try self.insertItem(d, trigger: "email_received")
            }
        }
        XCTAssertEqual(try read().inbox.count, 3)
    }

    func testRowsAreCappedAt200NewestFirst() throws {
        try db.write { d in
            for hour in 0..<210 {
                try self.insertItem(d, createdAt: self.iso(self.now.addingTimeInterval(-Double(hour) * 60)))
            }
        }
        let rows = try read().inbox
        XCTAssertEqual(rows.count, 200)
        XCTAssertEqual(rows.map(\.stamp), rows.map(\.stamp).sorted(by: >))
    }

    func testReadRowStaysInTheFeed() throws {
        try db.write { d in
            try self.insertItem(d, readAt: self.hoursAgo(0.5))
        }
        let data = try read()
        XCTAssertEqual(data.inbox.count, 1)
        XCTAssertFalse(data.inbox[0].item.readAt.isEmpty)
    }

    func testSlackWhoAndWhere() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "U002", name: "ann", displayName: "Ann", realName: "Ann A")
            try TestDatabase.insertChannel(d, id: "C001", name: "eng")
            try self.insertItem(d, trigger: "mention", channelID: "C001", sender: "U002")
        }
        let row = try XCTUnwrap(try read().inbox.first)
        XCTAssertEqual(row.who, "Ann")
        XCTAssertEqual(row.whereText, "#eng")
    }

    func testEmailWhoIsTheAddressAndWhereTheSubject() throws {
        try db.write { d in
            try self.insertItem(
                d, trigger: "email_received", channelID: "", sender: "bob@example.com",
                snippet: "Invoice 12 — please confirm the amount"
            )
        }
        let row = try XCTUnwrap(try read().inbox.first)
        XCTAssertEqual(row.who, "bob@example.com")
        XCTAssertEqual(row.whereText, "Invoice 12")
    }

    private func insertJiraIssue(_ d: Database, key: String, deleted: Bool = false) throws {
        let acct = try TestDatabase.insertJiraAccount(d, cloudID: "c-\(key)")
        try d.execute(sql: """
            INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                                     created_at, updated_at, synced_at, is_deleted)
            VALUES (?, ?, 'ACME', 'x', 'Open', 'todo', 't', 't', 't', ?)
            """, arguments: [acct, key, deleted ? 1 : 0])
    }

    func testJiraRowOfAnIssueDeletedAtTheSourceLeavesTheFeed() throws {
        try db.write { d in
            try self.insertJiraIssue(d, key: "ACME-1")
            try self.insertJiraIssue(d, key: "ACME-2", deleted: true)
            try self.insertItem(d, trigger: "jira_assigned", channelID: "ACME-1")
            try self.insertItem(d, trigger: "jira_assigned", channelID: "ACME-2")
            // Gone entirely: DeleteJiraIssues hard-deletes the issue.
            try self.insertItem(d, trigger: "jira_comment_mention", channelID: "ACME-3", snippet: "")
        }
        XCTAssertEqual(try read().inbox.map(\.who), ["ACME-1"])
    }

    func testJiraWhoIsTheIssueKeyAndWhereTheReason() throws {
        try db.write { d in
            try self.insertJiraIssue(d, key: "ACME-7")
            try self.insertJiraIssue(d, key: "ACME-8")
            try self.insertItem(d, trigger: "jira_assigned", channelID: "ACME-7")
            try self.insertItem(d, trigger: "jira_comment_mention", channelID: "ACME-8")
        }
        let rows = try read().inbox
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.who, $0.whereText) })
        XCTAssertEqual(byKey["ACME-7"], "assigned to you")
        XCTAssertEqual(byKey["ACME-8"], "mentioned you")
    }

    func testLinearWhoIsTheIssueKeyAndWhereTheReason() throws {
        try db.write { d in
            try self.insertItem(d, trigger: "linear_assigned", channelID: "ACME-9")
            try self.insertItem(d, trigger: "linear_comment_mention", channelID: "ACME-10")
        }
        let rows = try read().inbox
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.who, $0.whereText) })
        XCTAssertEqual(byKey["ACME-9"], "assigned to you")
        XCTAssertEqual(byKey["ACME-10"], "mentioned you")
    }

    // MARK: - Targets

    func testProj01_FeedNeverReturnsAProjectTarget() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO projects (id, name, folder_path) VALUES (1, 'wb', '/tmp/wb')")
            try self.insertTarget(d, "Workbench overdue", dueDate: try self.dayString(-1) + "T09:00", projectID: 1)
            try self.insertTarget(d, "Mine overdue", dueDate: try self.dayString(-1) + "T09:00")
        }
        XCTAssertEqual(try read().targets.map(\.text), ["Mine overdue"])
    }

    func testInProgressWithoutDueIsNotATargetRow() throws {
        try db.write { d in
            try self.insertTarget(d, "Working on it", status: "in_progress")
            try self.insertTarget(d, "Due today", dueDate: try self.dayString(0) + "T15:00")
            try self.insertTarget(d, "Due tomorrow", dueDate: try self.dayString(1) + "T09:00")
        }
        XCTAssertEqual(try read().targets.map(\.text), ["Due today"])
    }

    /// The read takes every due target (the inbox's 200 bound), not the
    /// first seven: the builder caps what shows, and a target due later
    /// today sorts last by `due_date` yet belongs below NOW.
    func testEveryDueTargetReachesTheFeed() throws {
        try db.write { d in
            for day in 1...8 {
                try self.insertTarget(d, "Overdue \(day)", dueDate: try self.dayString(-day))
            }
            try self.insertTarget(d, "Due today", dueDate: try self.dayString(0))
            try self.insertTarget(d, "Later today", dueDate: try self.dayString(0) + "T23:59")
        }
        let data = try read()
        XCTAssertEqual(data.targets.count, 10)
        let feed = HomeFeedBuilder.feed(data, now: now, calendar: calendar, expanded: false, hidden: [])
        XCTAssertEqual(feed.laterToday.map(\.title), ["Later today"])
        XCTAssertEqual(feed.waiting.count + feed.hiddenWaiting, 9)
    }

    // MARK: - Calendar

    private func insertEvent(
        _ d: Database,
        _ id: String,
        start: Date,
        minutes: Int = 30,
        allDay: Bool = false,
        status: String = "confirmed",
        attendees: String = "[]"
    ) throws {
        try TestDatabase.insertCalendarEvent(
            d, id: id, title: id, startTime: iso(start),
            endTime: iso(start.addingTimeInterval(Double(minutes) * 60)),
            isAllDay: allDay, attendees: attendees, eventStatus: status
        )
    }

    func testEventsDropAllDayCancelledAndDeclined() throws {
        let owner = "me@example.com"
        let declined = #"[{"email":"me@example.com","display_name":"","response_status":"declined","slack_user_id":""}]"#
        let accepted = #"[{"email":"me@example.com","display_name":"","response_status":"accepted","slack_user_id":""}]"#
        try db.write { d in
            let accountID = try TestDatabase.insertGoogleAccount(d, email: owner, calendarEnabled: true)
            try TestDatabase.ensureCalendar(d, id: "work", accountID: accountID)
            let start = self.now.addingTimeInterval(3600)
            try self.insertEvent(d, "keep", start: start)
            try self.insertEvent(d, "allday", start: start, allDay: true)
            try self.insertEvent(d, "cancelled", start: start, status: "cancelled")
            try TestDatabase.insertCalendarEvent(
                d, id: "declined", calendarID: "work", title: "declined", startTime: self.iso(start),
                endTime: self.iso(start.addingTimeInterval(1800)), attendees: declined
            )
            try TestDatabase.insertCalendarEvent(
                d, id: "accepted", calendarID: "work", title: "accepted", startTime: self.iso(start),
                endTime: self.iso(start.addingTimeInterval(1800)), attendees: accepted
            )
        }
        let ids = Set(try read().events.map(\.id))
        XCTAssertEqual(ids, ["keep", "accepted"])
    }

    func testIsShownEvent() throws {
        func event(allDay: Bool = false, status: String = "confirmed", response: String = "accepted") throws -> CalendarEvent {
            let attendees = #"[{"email":"Me@Example.com","display_name":"","response_status":"\#(response)","slack_user_id":""}]"#
            return try db.write { d in
                let accountID = try TestDatabase.insertGoogleAccount(d, email: "me@example.com", calendarEnabled: true)
                try TestDatabase.ensureCalendar(d, id: "cal\(accountID)", accountID: accountID)
                try TestDatabase.insertCalendarEvent(
                    d, id: "e\(accountID)", calendarID: "cal\(accountID)", isAllDay: allDay,
                    attendees: attendees, eventStatus: status
                )
                return try XCTUnwrap(try CalendarQueries.fetchEvent(d, id: "e\(accountID)"))
            }
        }
        XCTAssertTrue(HomeFeedQueries.isShownEvent(try event()))
        XCTAssertFalse(HomeFeedQueries.isShownEvent(try event(allDay: true)))
        XCTAssertFalse(HomeFeedQueries.isShownEvent(try event(status: "cancelled")))
        XCTAssertFalse(HomeFeedQueries.isShownEvent(try event(response: "declined")))
    }

    func testPrepIsReadForTodayAndTheNextDayOnly() throws {
        try db.write { d in
            try self.insertEvent(d, "today", start: self.now.addingTimeInterval(3600))
            try self.insertEvent(d, "tomorrow", start: self.now.addingTimeInterval(26 * 3600))
            try self.insertEvent(d, "later", start: self.now.addingTimeInterval(50 * 3600))
            for id in ["today", "tomorrow", "later"] {
                try d.execute(
                    sql: "INSERT INTO meeting_prep_cache (event_id, result_json) VALUES (?, '{\"a\":1}')",
                    arguments: [id]
                )
            }
        }
        XCTAssertEqual(try read().prepEventIDs, ["today", "tomorrow"])
    }

    // MARK: - Reminders and proposals

    func testRemindersSplitDueAndLaterToday() throws {
        try db.write { d in
            let sql = "INSERT INTO reminders (remind_at, status, note) VALUES (?, ?, ?)"
            try d.execute(sql: sql, arguments: [self.hoursAgo(1), "pending", "due"])
            try d.execute(sql: sql, arguments: [self.iso(self.now.addingTimeInterval(3600)), "pending", "later"])
            try d.execute(sql: sql, arguments: [self.iso(self.now.addingTimeInterval(30 * 3600)), "pending", "tomorrow"])
            try d.execute(sql: sql, arguments: [self.iso(self.now.addingTimeInterval(7200)), "done", "done"])
        }
        let data = try read()
        XCTAssertEqual(data.dueReminders.map(\.note), ["due"])
        XCTAssertEqual(data.laterReminders.map(\.note), ["later"])
    }

    /// Every proposal waiting on the owner is read, not the first seven.
    func testEveryAwaitingProposalIsRead() throws {
        try db.write { d in
            for index in 1...8 {
                try TestDatabase.insertAgentAction(d, turnID: "turn-\(index)")
            }
        }
        XCTAssertEqual(try read().proposals.count, 8)
    }

    // MARK: - Automation outputs

    /// Unread inbox outputs of the last 72 hours; read, dismissed, older and
    /// report / briefing outputs stay out.
    func testAutomationOutputsAreUnreadInboxOnesOfTheWindow() throws {
        let shown = try db.write { d -> Int64 in
            let id = try TestDatabase.insertAutomation(d, name: "Mail summary")
            let run = try TestDatabase.insertAutomationRun(d, automationID: id)
            let shown = try TestDatabase.insertAutomationOutput(
                d, automationID: id, runID: run, title: "shown", createdAt: self.hoursAgo(71))
            try TestDatabase.insertAutomationOutput(d, automationID: id, runID: run, createdAt: self.hoursAgo(73))
            try TestDatabase.insertAutomationOutput(
                d, automationID: id, runID: run, kind: "report", createdAt: self.hoursAgo(1))
            try TestDatabase.insertAutomationOutput(
                d, automationID: id, runID: run, createdAt: self.hoursAgo(2), readAt: self.hoursAgo(1))
            try TestDatabase.insertAutomationOutput(
                d, automationID: id, runID: run, createdAt: self.hoursAgo(2), dismissedAt: self.hoursAgo(1))
            return shown
        }
        let data = try read()
        XCTAssertEqual(data.outputs.map(\.id), [shown])
        XCTAssertEqual(data.outputs.first?.automationName, "Mail summary")
        XCTAssertTrue(data.failed.isEmpty)
    }

    // MARK: - Failure

    /// One source that throws is named in `failed` and hides only itself.
    func testOneFailingSourceMarksOnlyItself() throws {
        try db.write { d in
            try self.insertItem(d)
            // The column the read needs is gone.
            try d.execute(sql: "DROP TABLE reminders")
            try d.execute(sql: "CREATE TABLE reminders (id INTEGER PRIMARY KEY, status TEXT)")
        }
        let data = try read()
        XCTAssertEqual(data.failed, [.reminders])
        XCTAssertEqual(data.inbox.count, 1)
    }

    /// A table missing mid-migration is no content, not a failure.
    func testMissingTableReadsAsEmpty() throws {
        try db.write { d in
            try d.execute(sql: "DROP TABLE reminders")
        }
        let data = try read()
        XCTAssertTrue(data.failed.isEmpty)
        XCTAssertTrue(data.dueReminders.isEmpty)
    }
}
