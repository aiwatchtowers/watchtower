import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The reads behind Home's Today cards: my targets due today, open asks
/// across workbenches.
final class HomeQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    /// `yyyy-MM-dd` `days` from today, local — the form `todayDateString()` uses.
    private func day(_ days: Int) throws -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: days, to: Date())))
    }

    /// A `created_at`/`updated_at` `minutes` before now, in the column's UTC form.
    private func stamp(minutesAgo minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
    }

    @discardableResult
    private func insertTarget(
        _ d: Database,
        _ text: String,
        status: String = "todo",
        ownership: String = "mine",
        dueDate: String = "",
        updatedAt: String? = nil
    ) throws -> Int64 {
        let today = try day(0)
        try d.execute(
            sql: """
                INSERT INTO targets (text, level, period_start, period_end, status, ownership, due_date,
                    source_type, updated_at)
                VALUES (?, 'day', ?, ?, ?, ?, ?, 'manual', COALESCE(?, strftime('%Y-%m-%dT%H:%M:%SZ','now')))
                """,
            arguments: [text, today, today, status, ownership, dueDate, updatedAt]
        )
        return d.lastInsertedRowID
    }

    // MARK: - homeSummary

    func testHomeSummaryPicksDueTodayOverdueAndInProgressMine() throws {
        let texts = try db.write { d in
            try self.insertTarget(d, "Overdue", dueDate: self.day(-1) + "T09:00")
            try self.insertTarget(d, "Due today", dueDate: self.day(0) + "T15:00")
            try self.insertTarget(d, "Due tomorrow", dueDate: self.day(1) + "T09:00")
            try self.insertTarget(d, "In progress", status: "in_progress")
            try self.insertTarget(d, "Someday")
            return try TargetQueries.homeSummary(d, today: self.day(0)).map(\.text)
        }
        XCTAssertEqual(texts, ["Overdue", "Due today", "In progress"])
    }

    func testHomeSummarySkipsOthersOwnership() throws {
        let texts = try db.write { d in
            try self.insertTarget(d, "Delegated", ownership: "delegated", dueDate: self.day(0) + "T10:00")
            try self.insertTarget(d, "Watching", ownership: "watching", dueDate: self.day(0) + "T10:00")
            return try TargetQueries.homeSummary(d, today: self.day(0)).map(\.text)
        }
        XCTAssertEqual(texts, [])
    }

    func testHomeSummarySkipsClosedAndSnoozed() throws {
        let texts = try db.write { d in
            for status in ["done", "dismissed", "snoozed"] {
                try self.insertTarget(d, status, status: status, dueDate: self.day(0) + "T10:00")
            }
            return try TargetQueries.homeSummary(d, today: self.day(0)).map(\.text)
        }
        XCTAssertEqual(texts, [])
    }

    func testHomeSummaryLimitsToFive() throws {
        let count = try db.write { d in
            for i in 0..<7 {
                try self.insertTarget(d, "Due \(i)", dueDate: self.day(0) + "T1\(i):00")
            }
            return try TargetQueries.homeSummary(d, today: self.day(0)).count
        }
        XCTAssertEqual(count, 5)
    }

    // MARK: - openAsksAllWorkbenches

    func testOpenAsksAllWorkbenchesSpansWorkbenches() throws {
        let (result, older, newer) = try db.write { d in
            let acme = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            let beta = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            let newer = try TestDatabase.insertOwnerAsk(d, projectID: acme, createdAt: self.stamp(minutesAgo: 1))
            let older = try TestDatabase.insertOwnerAsk(d, projectID: beta, createdAt: self.stamp(minutesAgo: 5))
            try TestDatabase.insertOwnerAsk(d, projectID: acme, status: "answered", answer: "{}",
                                            createdAt: self.stamp(minutesAgo: 10))
            return (try OwnerAskQueries.openAsksAllWorkbenches(d), older, newer)
        }
        XCTAssertEqual(result.rows.map(\.ask.id), [older, newer])
        XCTAssertEqual(result.rows.map(\.workbenchName), ["beta", "acme"])
        XCTAssertEqual(result.unreadableIDs, [])
    }

    func testOpenAsksAllWorkbenchesNamesUnreadableRows() throws {
        let (result, good, bad) = try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let good = try TestDatabase.insertOwnerAsk(d, projectID: p, createdAt: self.stamp(minutesAgo: 2))
            // The column's CHECK refuses 'poll'; a newer Go could still widen it.
            try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try d.execute(
                sql: "INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'poll', 'Pick one')",
                arguments: [p]
            )
            let bad = d.lastInsertedRowID
            try d.execute(sql: "PRAGMA ignore_check_constraints = OFF")
            return (try OwnerAskQueries.openAsksAllWorkbenches(d), good, bad)
        }
        XCTAssertEqual(result.rows.map(\.ask.id), [good])
        XCTAssertEqual(result.unreadableIDs, [bad])
    }

    func testOpenAsksAllWorkbenchesEmpty() throws {
        let result = try db.read { try OwnerAskQueries.openAsksAllWorkbenches($0) }
        XCTAssertTrue(result.rows.isEmpty && result.unreadableIDs.isEmpty)
    }

    // MARK: - awaitingOwner

    func testAwaitingOwnerMatchesTheBadgeCount() throws {
        let (rows, count) = try db.write { d in
            try TestDatabase.insertAgentAction(d, turnID: "pending-old", status: "pending",
                                               createdAt: self.stamp(minutesAgo: 30))
            try TestDatabase.insertAgentAction(d, turnID: "failed-new", status: "failed",
                                               createdAt: self.stamp(minutesAgo: 10))
            try TestDatabase.insertAgentAction(d, turnID: "applied", status: "applied",
                                               createdAt: self.stamp(minutesAgo: 5))
            try TestDatabase.insertAgentAction(d, turnID: "executing", status: "executing",
                                               createdAt: self.stamp(minutesAgo: 4))
            try TestDatabase.insertAgentAction(d, contextType: "project", contextID: "7", turnID: "workbench",
                                               status: "pending", createdAt: self.stamp(minutesAgo: 1))
            return (try AgentActionQueries.awaitingOwner(d, limit: 10),
                    try AgentActionQueries.awaitingOwnerCount(d))
        }
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(rows.map(\.turnID), ["failed-new", "pending-old"])
    }

    func testAwaitingOwnerLimit() throws {
        let rows = try db.write { d in
            for i in 0..<5 {
                try TestDatabase.insertAgentAction(d, turnID: "t\(i)", createdAt: self.stamp(minutesAgo: Double(i)))
            }
            return try AgentActionQueries.awaitingOwner(d, limit: 3)
        }
        XCTAssertEqual(rows.map(\.turnID), ["t0", "t1", "t2"])
    }

    // MARK: - hasPrep

    func testHasPrepFalseForEmptyResult() throws {
        try db.write { d in
            try d.execute(sql: "INSERT INTO meeting_prep_cache (event_id, result_json) VALUES ('empty', '')")
            try d.execute(sql: #"INSERT INTO meeting_prep_cache (event_id, result_json) VALUES ('ready', '{"talking_points":[]}')"#)
        }
        try db.read { d in
            XCTAssertFalse(try CalendarQueries.hasPrep(d, eventID: "empty"))
            XCTAssertFalse(try CalendarQueries.hasPrep(d, eventID: "missing"))
            XCTAssertTrue(try CalendarQueries.hasPrep(d, eventID: "ready"))
        }
    }

    // MARK: - WorkbenchRoute.forAsk

    func testAskRouteSessionOpensTerminal() {
        let session = WorkbenchRoute.forAsk(projectID: 1, sessionID: 7, askID: 3)
        XCTAssertEqual(session, WorkbenchRoute(projectID: 1, pane: .terminal, subjectID: 7, askID: 3))
        let outside = WorkbenchRoute.forAsk(projectID: 1, sessionID: nil, askID: 3)
        XCTAssertEqual(outside, WorkbenchRoute(projectID: 1, pane: .board, askID: 3))
        XCTAssertNil(outside.subjectID)
    }

    // MARK: - today

    func testTodayEmptyDatabaseReadsNoContent() throws {
        let data = try db.read { HomeQueries.today($0, now: Date(), calendar: .current) }
        XCTAssertEqual(data.awaitingCount, 0)
        XCTAssertTrue(data.actions.isEmpty)
        XCTAssertTrue(data.reminders.isEmpty)
        XCTAssertNil(data.nextEvent)
        XCTAssertFalse(data.nextEventHasPrep)
        XCTAssertNil(data.briefing)
        XCTAssertTrue(data.targets.isEmpty)
        XCTAssertTrue(data.asks.rows.isEmpty && data.asks.unreadableIDs.isEmpty)
        XCTAssertNil(data.latestRecap)
        XCTAssertTrue(data.failed.isEmpty)
    }

    func testTodayReadsEverySource() throws {
        let now = Date()
        let data = try db.write { d in
            try TestDatabase.insertAgentAction(d, turnID: "pending", createdAt: self.stamp(minutesAgo: 3))
            try d.execute(sql: "INSERT INTO reminders (note, remind_at) VALUES ('Call back', ?)",
                          arguments: [self.stamp(minutesAgo: 1)])
            try TestDatabase.insertCalendarEvent(d, id: "evt-home", startTime: self.stamp(minutesAgo: -60),
                                                 endTime: self.stamp(minutesAgo: -90))
            try TestDatabase.insertMeetingPrep(d, eventID: "evt-home", resultJSON: #"{"talking_points":[]}"#)
            try TestDatabase.insertBriefing(d, date: self.day(0), attention: #"[{"text":"Reply to acme"}]"#)
            try self.insertTarget(d, "Due today", dueDate: self.day(0) + "T15:00")
            let workbench = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            try TestDatabase.insertOwnerAsk(d, projectID: workbench)
            try d.execute(sql: "INSERT INTO catchup_recaps (period_from, period_to, status, tldr) VALUES (?, ?, 'ready', 'All quiet')",
                          arguments: [now.timeIntervalSince1970 - 3600, now.timeIntervalSince1970])
            return HomeQueries.today(d, now: now, calendar: .current)
        }
        XCTAssertEqual(data.awaitingCount, 1)
        XCTAssertEqual(data.actions.map(\.turnID), ["pending"])
        XCTAssertEqual(data.reminders.map(\.note), ["Call back"])
        XCTAssertEqual(data.nextEvent?.id, "evt-home")
        XCTAssertTrue(data.nextEventHasPrep)
        XCTAssertEqual(data.briefing?.date, try day(0))
        XCTAssertEqual(data.targets.map(\.text), ["Due today"])
        XCTAssertEqual(data.asks.rows.map(\.workbenchName), ["acme"])
        XCTAssertEqual(data.latestRecap?.tldr, "All quiet")
        XCTAssertTrue(data.failed.isEmpty)
    }

    /// Review Focus 3: a card whose read throws is named in `failed` and
    /// hides only itself; a table missing mid-migration is no content.
    func testOneFailingCardKeepsTheOthers() throws {
        let data = try db.write { d in
            try self.insertTarget(d, "Due today", dueDate: self.day(0) + "T15:00")
            try TestDatabase.insertBriefing(d, date: self.day(0), attention: #"[{"text":"Reply to acme"}]"#)
            try d.execute(sql: "DROP TABLE owner_asks")
            // The table-recreate dance with `date` renamed: the read's column is gone.
            try d.execute(sql: """
                CREATE TABLE briefings_new (id INTEGER PRIMARY KEY, day TEXT NOT NULL, created_at TEXT NOT NULL);
                INSERT INTO briefings_new (id, day, created_at) SELECT id, date, created_at FROM briefings;
                DROP TABLE briefings;
                ALTER TABLE briefings_new RENAME TO briefings;
                """)
            return HomeQueries.today(d, now: Date(), calendar: .current)
        }
        XCTAssertEqual(data.failed, [.briefing])
        XCTAssertNil(data.briefing)
        XCTAssertTrue(data.asks.rows.isEmpty)
        XCTAssertEqual(data.targets.map(\.text), ["Due today"])
    }

    func testObservedTablesCoverEveryRead() {
        for table in ["agent_actions", "reminders", "calendar_events", "meeting_prep_cache", "briefings",
                      "targets", "owner_asks", "projects", "catchup_recaps"] {
            XCTAssertTrue(HomeQueries.observedTables.contains(table), table)
        }
    }
}
