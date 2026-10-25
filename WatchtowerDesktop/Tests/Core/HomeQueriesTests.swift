import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The reads behind Home: my targets due today, open asks across
/// workbenches, the Workbench zone's read.
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
    private func stampAgo(minutesAgo minutes: Double) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutes * 60))
    }

    /// An open ask `OwnerAsk(row:)` refuses: the column's CHECK refuses
    /// 'poll', but a newer Go could still widen it.
    @discardableResult
    private func insertUnreadableAsk(_ d: Database, projectID: Int64) throws -> Int64 {
        try d.execute(sql: "PRAGMA ignore_check_constraints = ON")
        try d.execute(
            sql: "INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'poll', 'Pick one')",
            arguments: [projectID]
        )
        let id = d.lastInsertedRowID
        try d.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        return id
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

    func testHomeSummaryInProgressWithFutureDueSortsAfterDueByUpdatedAt() throws {
        let texts = try db.write { d in
            try self.insertTarget(d, "Older in progress", status: "in_progress", dueDate: self.day(2) + "T09:00",
                                  updatedAt: self.stampAgo(minutesAgo: 60))
            try self.insertTarget(d, "Newer in progress", status: "in_progress", dueDate: self.day(1) + "T09:00",
                                  updatedAt: self.stampAgo(minutesAgo: 5))
            try self.insertTarget(d, "Due today", dueDate: self.day(0) + "T15:00",
                                  updatedAt: self.stampAgo(minutesAgo: 120))
            try self.insertTarget(d, "Overdue", dueDate: self.day(-2) + "T09:00",
                                  updatedAt: self.stampAgo(minutesAgo: 1))
            return try TargetQueries.homeSummary(d, today: self.day(0)).map(\.text)
        }
        XCTAssertEqual(texts, ["Overdue", "Due today", "Newer in progress", "Older in progress"])
    }

    func testHomeSummaryIncludesBlockedDueToday() throws {
        let texts = try db.write { d in
            try self.insertTarget(d, "Blocked today", status: "blocked", dueDate: self.day(0) + "T11:00")
            try self.insertTarget(d, "Blocked tomorrow", status: "blocked", dueDate: self.day(1) + "T11:00")
            try self.insertTarget(d, "Blocked undated", status: "blocked")
            return try TargetQueries.homeSummary(d, today: self.day(0)).map(\.text)
        }
        XCTAssertEqual(texts, ["Blocked today"])
    }

    /// Over five matches: every due row (earliest first) beats in-progress,
    /// and the newest in-progress fills what is left.
    func testHomeSummaryKeepsTheFiveFirstInOrder() throws {
        let texts = try db.write { d in
            for (i, minutes) in [30.0, 10.0, 20.0].enumerated() {
                try self.insertTarget(d, "In progress \(i)", status: "in_progress",
                                      updatedAt: self.stampAgo(minutesAgo: minutes))
            }
            try self.insertTarget(d, "Due 15", dueDate: self.day(0) + "T15:00")
            try self.insertTarget(d, "Due 09", dueDate: self.day(0) + "T09:00")
            try self.insertTarget(d, "Overdue", dueDate: self.day(-1) + "T18:00")
            try self.insertTarget(d, "Due 12", dueDate: self.day(0) + "T12:00")
            return try TargetQueries.homeSummary(d, today: self.day(0)).map(\.text)
        }
        XCTAssertEqual(texts, ["Overdue", "Due 09", "Due 12", "Due 15", "In progress 1"])
    }

    // MARK: - openAsksAllWorkbenches

    func testOpenAsksAllWorkbenchesSpansWorkbenches() throws {
        let (result, older, newer) = try db.write { d in
            let acme = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            let beta = try TestDatabase.insertWorkbench(d, name: "beta", folder: "/tmp/beta")
            let newer = try TestDatabase.insertOwnerAsk(d, projectID: acme, createdAt: self.stampAgo(minutesAgo: 1))
            let older = try TestDatabase.insertOwnerAsk(d, projectID: beta, createdAt: self.stampAgo(minutesAgo: 5))
            try TestDatabase.insertOwnerAsk(d, projectID: acme, status: "answered", answer: "{}",
                                            createdAt: self.stampAgo(minutesAgo: 10))
            return (try OwnerAskQueries.openAsksAllWorkbenches(d), older, newer)
        }
        XCTAssertEqual(result.rows.map(\.ask.id), [older, newer])
        XCTAssertEqual(result.rows.map(\.workbenchName), ["beta", "acme"])
        XCTAssertEqual(result.unreadableIDs, [])
    }

    func testOpenAsksAllWorkbenchesNamesUnreadableRows() throws {
        let (result, good, bad) = try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let good = try TestDatabase.insertOwnerAsk(d, projectID: p, createdAt: self.stampAgo(minutesAgo: 2))
            let bad = try self.insertUnreadableAsk(d, projectID: p)
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
                                               createdAt: self.stampAgo(minutesAgo: 30))
            try TestDatabase.insertAgentAction(d, turnID: "failed-new", status: "failed",
                                               createdAt: self.stampAgo(minutesAgo: 10))
            try TestDatabase.insertAgentAction(d, turnID: "applied", status: "applied",
                                               createdAt: self.stampAgo(minutesAgo: 5))
            try TestDatabase.insertAgentAction(d, turnID: "executing", status: "executing",
                                               createdAt: self.stampAgo(minutesAgo: 4))
            try TestDatabase.insertAgentAction(d, contextType: "project", contextID: "7", turnID: "workbench",
                                               status: "pending", createdAt: self.stampAgo(minutesAgo: 1))
            return (try AgentActionQueries.awaitingOwner(d, limit: 10),
                    try AgentActionQueries.awaitingOwnerCount(d))
        }
        XCTAssertEqual(rows.count, count)
        XCTAssertEqual(rows.map(\.turnID), ["failed-new", "pending-old"])
    }

    func testAwaitingOwnerLimit() throws {
        let rows = try db.write { d in
            for i in 0..<5 {
                try TestDatabase.insertAgentAction(d, turnID: "t\(i)", createdAt: self.stampAgo(minutesAgo: Double(i)))
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

    // MARK: - workbench

    func testWorkbenchEmptyDatabaseReadsNoContent() throws {
        let data = try db.read { HomeQueries.workbench($0, now: Date()) }
        XCTAssertTrue(data.asks.rows.isEmpty && data.asks.unreadableIDs.isEmpty)
        XCTAssertNil(data.suggestion)
        XCTAssertFalse(data.failed)
    }

    /// Review Focus 3: a source whose read throws marks the data failed and
    /// keeps the other; a table missing mid-migration is no content.
    func testOneFailingSourceKeepsTheOther() throws {
        let data = try db.write { d in
            let p = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            try TestDatabase.insertOwnerAsk(d, projectID: p, title: "Check the build")
            try d.execute(sql: """
                DROP TABLE instruction_suggestions;
                CREATE TABLE instruction_suggestions (id INTEGER PRIMARY KEY, body TEXT);
                """)
            return HomeQueries.workbench(d, now: Date())
        }
        XCTAssertTrue(data.failed)
        XCTAssertNil(data.suggestion)
        XCTAssertEqual(data.asks.rows.map(\.ask.title), ["Check the build"])

        let missing = try db.write { d in
            try d.execute(sql: "DROP TABLE instruction_suggestions")
            return HomeQueries.workbench(d, now: Date())
        }
        XCTAssertFalse(missing.failed)
    }

    /// An unreadable ask is a failed read (never an empty zone); the readable
    /// asks still show.
    func testUnreadableAskMarksWorkbenchFailedAndKeepsReadableRows() throws {
        let data = try db.write { d in
            let p = try TestDatabase.insertWorkbench(d, name: "acme", folder: "/tmp/acme")
            try TestDatabase.insertOwnerAsk(d, projectID: p, title: "Check the build")
            try self.insertUnreadableAsk(d, projectID: p)
            return HomeQueries.workbench(d, now: Date())
        }
        XCTAssertTrue(data.failed)
        XCTAssertEqual(data.asks.rows.map(\.ask.title), ["Check the build"])
    }

    func testObservedTablesCoverEveryRead() {
        for table in ["owner_asks", "projects", "instruction_suggestions"] {
            XCTAssertTrue(HomeQueries.observedTables.contains(table), table)
        }
    }

    /// The feed, links and numbers own their tables; the Workbench read does
    /// not observe them.
    func testWorkbenchDoesNotObserveTheOtherZonesTables() {
        for table in ["agent_actions", "reminders", "targets", "calendar_events", "briefings", "catchup_recaps",
                      "messages"] {
            XCTAssertFalse(HomeQueries.observedTables.contains(table), table)
        }
    }

    // MARK: - Instruction suggestion

    private func insertSuggestion(
        _ d: Database, _ text: String, status: String = "open", daysAgo: Double = 1, field: String = "session"
    ) throws {
        let seen = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 86400))
        try d.execute(
            sql: """
                INSERT INTO instruction_suggestions (text, field, first_seen_at, last_seen_at, status, fingerprint)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [text, field, seen, seen, status, text])
    }

    private func suggestionRead() throws -> HomeWorkbenchData {
        try db.read { HomeQueries.workbench($0, now: Date()) }
    }

    func testInstructionSuggestionCardShowsNewest() throws {
        try db.write { d in
            try insertSuggestion(d, "older", daysAgo: 3)
            try insertSuggestion(d, "newest", daysAgo: 1)
        }
        XCTAssertEqual(try suggestionRead().suggestion?.text, "newest")
    }

    func testInstructionSuggestionCarriesItsField() throws {
        try db.write { try insertSuggestion($0, "answer in English", field: "chat") }
        let suggestion = try XCTUnwrap(try suggestionRead().suggestion)
        XCTAssertEqual(suggestion.field, "chat")
    }

    func testInstructionSuggestionCardHiddenAfterSevenDays() throws {
        try db.write { try insertSuggestion($0, "stale", daysAgo: 8) }
        XCTAssertNil(try suggestionRead().suggestion)
    }

    func testInstructionSuggestionCardHiddenWhenDecided() throws {
        try db.write { d in
            try insertSuggestion(d, "added", status: "added")
            try insertSuggestion(d, "dismissed", status: "dismissed")
        }
        XCTAssertNil(try suggestionRead().suggestion)
    }

    func testSecondOpenSuggestionShowsAfterFirstIsDecided() throws {
        try db.write { d in
            try insertSuggestion(d, "first", daysAgo: 1)
            try insertSuggestion(d, "second", daysAgo: 2)
        }
        XCTAssertEqual(try suggestionRead().suggestion?.text, "first")
        try db.write { try $0.execute(sql: "UPDATE instruction_suggestions SET status = 'added' WHERE text = 'first'") }
        XCTAssertEqual(try suggestionRead().suggestion?.text, "second")
    }
}
