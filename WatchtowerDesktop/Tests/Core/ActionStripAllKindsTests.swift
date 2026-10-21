import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox view model over every kind (C1 Task 5): one pure read
/// (STRIP-02 extended), the opening writes per kind, the track and message
/// buttons, the remembered filter and day Done, and the on-screen poll.
@MainActor
final class ActionStripAllKindsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var pool: DatabasePool!
    private var path = ""

    override func setUp() async throws {
        suiteName = "ActionStripAllKindsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        (pool, path) = try TestDatabase.createPool()
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        pool = nil
        TestDatabase.cleanup(path: path)
    }

    private var today: String { HomeFeedBuilder.dayString(Date(), calendar: .current) }

    private func makeVM(_ runner: CLIRunnerProtocol = FakeCLIRunner()) -> ActionStripViewModel {
        ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults)
    }

    nonisolated private static func message(_ db: Database, _ n: Int, created: String = "2026-10-21T07:00:00Z") throws -> Int {
        let id = try TestDatabase.insertInboxItem(db, messageTS: "1700000\(String(format: "%04d", n)).000100")
        try db.execute(sql: "UPDATE inbox_items SET created_at = ? WHERE id = ?", arguments: [created, id])
        return Int(id)
    }

    private func dump(_ tables: [String]) throws -> [[String]] {
        try pool.read { db in
            try tables.map { table in
                try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid").map(\.description)
            }
        }
    }

    private func row(_ table: String, _ id: Int) throws -> Row {
        let fetched = try pool.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM \(table) WHERE id = ?", arguments: [id])
        }
        return try XCTUnwrap(fetched)
    }

    private func unreadEvents(_ trackID: Int) throws -> Int {
        try pool.read { try TrackEventQueries.unreadCount($0, trackId: trackID) }
    }

    private func assertOnlyChanged(
        _ column: String,
        before: Row,
        after: Row,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for name in after.columnNames where name != column {
            XCTAssertEqual(after[name] as DatabaseValue, before[name] as DatabaseValue, name, file: file, line: line)
        }
    }

    // MARK: - STRIP-02

    func testRefreshIsStillOnePureRead() async throws {
        let date = today
        try await pool.write { db in
            let automationID = try TestDatabase.insertAutomation(db, slug: "mail-summary", name: "Mail summary")
            let runID = try TestDatabase.insertAutomationRun(db, automationID: automationID)
            try TestDatabase.insertAutomationOutput(db, automationID: automationID, runID: runID)
            try TestDatabase.insertAgentAction(
                db, surface: "automation", conversationID: 0, contextType: "automation_run", contextID: String(runID))
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1','call back','2000-01-01T00:00:00Z','pending')
                """)
            try TestDatabase.insertBriefing(db, date: date)
            let plan = try TestDatabase.insertDayPlan(db, planDate: date)
            try TestDatabase.insertDayPlanItem(db, dayPlanID: plan, title: "A", status: "pending")
            let track = try TestDatabase.insertTrack(db, hasUpdates: true)
            try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 's')", arguments: [track])
            try TestDatabase.insertIdea(db, kind: "idea")
            _ = try Self.message(db, 1)
        }
        let tables = [
            "briefings", "day_plans", "day_plan_items", "tracks", "track_events", "ideas", "inbox_items",
            "agent_actions", "reminders", "automation_outputs", "automation_runs", "automations", "pipeline_runs"
        ]
        let before = try dump(tables)
        let vm = makeVM()

        vm.refresh()
        vm.refresh()

        XCTAssertEqual(try dump(tables), before)
        XCTAssertNil(vm.lastError)
        XCTAssertEqual(vm.feed.proposals.count, 1)
        XCTAssertEqual(vm.feed.reminders.count, 1)
        XCTAssertEqual(vm.feed.outputs.count, 1)
        XCTAssertEqual(vm.feed.days.map(\.date), [date])
        XCTAssertEqual(vm.feed.tracks.count, 1)
        XCTAssertEqual(vm.feed.ideas.count, 1)
        XCTAssertEqual(vm.feed.messages.count, 1)
        XCTAssertEqual(vm.actionRows, vm.feed.proposals)
        XCTAssertEqual(vm.reminderRows, vm.feed.reminders)
        XCTAssertEqual(vm.outputRows, vm.feed.outputs)
    }

    // MARK: - Opening

    func testOpeningTheDayCardMarksTheBriefingRead() async throws {
        let date = today
        let id = try await pool.write { db -> Int in
            try TestDatabase.insertBriefing(db, date: "2026-01-01")
            try TestDatabase.insertBriefing(db, date: date)
            return Int(db.lastInsertedRowID)
        }
        let other = try row("briefings", id - 1)
        let before = try row("briefings", id)
        let vm = makeVM()
        vm.refresh()

        await vm.select(.day(date))

        let after = try row("briefings", id)
        XCTAssertNotNil(after["read_at"] as String?)
        assertOnlyChanged("read_at", before: before, after: after)
        XCTAssertEqual(try row("briefings", id - 1), other)
        XCTAssertEqual(vm.selection, .day(date))
        XCTAssertEqual(vm.feed.days.first { $0.date == date }?.isUnread, false)
        XCTAssertNil(vm.lastError)
    }

    func testOpeningAMessageWritesOnlyReadAt() async throws {
        let id = try await pool.write { try Self.message($0, 1) }
        let before = try row("inbox_items", id)
        let vm = makeVM()
        vm.refresh()

        await vm.select(.message(id))

        let after = try row("inbox_items", id)
        XCTAssertNotNil(after["read_at"] as String?)
        XCTAssertNotEqual(after["read_at"] as String?, "")
        assertOnlyChanged("read_at", before: before, after: after)
        XCTAssertEqual(vm.feed.messages.map(\.item.isUnread), [false])
        XCTAssertNil(vm.lastError)
    }

    func testOpeningATrackWritesNothing() async throws {
        let id = try await pool.write { db -> Int in
            let track = try TestDatabase.insertTrack(db, hasUpdates: true)
            try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 's')", arguments: [track])
            try TestDatabase.insertIdea(db, kind: "idea")
            return Int(track)
        }
        let tables = ["tracks", "track_events", "ideas"]
        let before = try dump(tables)
        let vm = makeVM()
        vm.refresh()
        let idea = try XCTUnwrap(vm.feed.ideas.first)

        await vm.select(.track(id))
        await vm.select(.idea(idea.id))

        XCTAssertEqual(try dump(tables), before)
        XCTAssertEqual(vm.selection, .idea(idea.id))
    }

    // MARK: - Tracks

    func testTrackDoneMarksTrackAndEventsRead() async throws {
        let (id, other) = try await pool.write { db -> (Int, Int) in
            let track = try TestDatabase.insertTrack(db, hasUpdates: true)
            let other = try TestDatabase.insertTrack(db, hasUpdates: true)
            for owner in [track, track, other] {
                try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 's')", arguments: [owner])
            }
            return (Int(track), Int(other))
        }
        let vm = makeVM()
        vm.refresh()

        await vm.markTrackDone(id)

        let after = try row("tracks", id)
        XCTAssertEqual(after["has_updates"] as Int?, 0)
        XCTAssertNotNil(after["read_at"] as String?)
        XCTAssertEqual(try unreadEvents(id), 0)
        XCTAssertEqual(try unreadEvents(other), 1)
        XCTAssertEqual(try row("tracks", other)["has_updates"] as Int?, 1)
        XCTAssertEqual(vm.feed.tracks.first { $0.track.id == id }?.isUnread, false)
        XCTAssertNil(vm.lastError)
    }

    func testStopWatchingACustomTrackPausesIt() async throws {
        let (custom, auto) = try await pool.write { db -> (Int, Int) in
            let custom = try TestDatabase.insertTrack(db, text: "Watch the launch")
            try db.execute(sql: "UPDATE tracks SET origin = 'custom', enabled = 1 WHERE id = ?", arguments: [custom])
            let auto = try TestDatabase.insertTrack(db)
            return (Int(custom), Int(auto))
        }
        let vm = makeVM()
        vm.refresh()
        let cards = vm.feed.tracks.map(\.track)
        let customTrack = try XCTUnwrap(cards.first { $0.id == custom })
        let autoTrack = try XCTUnwrap(cards.first { $0.id == auto })
        XCTAssertTrue(customTrack.isCustom)
        XCTAssertFalse(autoTrack.isCustom)

        await vm.stopWatching(customTrack)
        await vm.stopWatching(autoTrack)

        let customRow = try row("tracks", custom)
        XCTAssertNotEqual(customRow["dismissed_at"] as String?, "")
        XCTAssertEqual(customRow["enabled"] as Int?, 0)
        let autoRow = try row("tracks", auto)
        XCTAssertNotEqual(autoRow["dismissed_at"] as String?, "")
        XCTAssertEqual(autoRow["enabled"] as Int?, 1)
        XCTAssertTrue(vm.feed.tracks.isEmpty)
        XCTAssertNil(vm.lastError)
    }

    // MARK: - Messages

    func testMessageButtonsRunTheInboxCLI() async throws {
        let id = try await pool.write { try Self.message($0, 1) }
        let runner = FakeCLIRunner()
        let vm = makeVM(runner)
        vm.refresh()

        await vm.messageDone(id)
        await vm.hideMessage(id)
        await vm.snoozeMessage(id, duration: "3d")

        XCTAssertEqual(runner.invocations, [
            ["inbox", "resolve", "\(id)"],
            ["inbox", "dismiss", "\(id)"],
            ["inbox", "snooze", "\(id)", "3d"]
        ])
        XCTAssertNil(vm.lastError)
        XCTAssertFalse(vm.isWriting(.message(id)))
    }

    func testAMessageCLIFailureSaysWhy() async throws {
        let id = try await pool.write { try Self.message($0, 1) }
        let vm = makeVM(FakeCLIRunner(error: CLIRunnerError.binaryNotFound))
        vm.refresh()

        await vm.messageDone(id)

        XCTAssertEqual(vm.lastError, CLIRunnerError.binaryNotFound.localizedDescription)
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id])
    }

    func testMessageDoneOnAResolvedItemIsQuiet() async throws {
        let id = try await pool.write { try Self.message($0, 1) }
        let vm = makeVM()
        vm.refresh()
        XCTAssertEqual(vm.feed.messages.count, 1)
        // INBOX-02 auto-resolved it after the list was read; the CLI exits 0.
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [id])
        }

        await vm.messageDone(id)

        XCTAssertNil(vm.lastError)
        XCTAssertTrue(vm.feed.messages.isEmpty)
    }

    func testSelectionMovesWhenTheSelectedRowVanished() async throws {
        let ids = try await pool.write { db in
            try [
                Self.message(db, 1, created: "2026-10-21T09:00:00Z"),
                Self.message(db, 2, created: "2026-10-21T08:00:00Z"),
                Self.message(db, 3, created: "2026-10-21T07:00:00Z")
            ]
        }
        let vm = makeVM()
        vm.filter = .messages
        vm.refresh()
        XCTAssertEqual(vm.sections.flatMap(\.items).map(\.id), ids.map { .message($0) })
        await vm.select(.message(ids[1]))
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id IN (?, ?)",
                           arguments: [ids[1], ids[2]])
        }

        await vm.pollTick()

        // The row below went too: the one above is opened.
        XCTAssertEqual(vm.selection, .message(ids[0]))
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [ids[0]])
        }
        await vm.pollTick()
        XCTAssertNil(vm.selection)
    }

    func testSelectionMovesToTheRowBelow() async throws {
        let ids = try await pool.write { db in
            try [
                Self.message(db, 1, created: "2026-10-21T09:00:00Z"),
                Self.message(db, 2, created: "2026-10-21T08:00:00Z"),
                Self.message(db, 3, created: "2026-10-21T07:00:00Z")
            ]
        }
        let vm = makeVM()
        vm.filter = .messages
        vm.refresh()
        await vm.select(.message(ids[1]))
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [ids[1]])
        }

        await vm.pollTick()

        XCTAssertEqual(vm.selection, .message(ids[2]))
    }

    // MARK: - Per-viewer state

    func testFilterAndDayDoneSurviveANewViewModel() {
        let vm = makeVM()
        XCTAssertEqual(vm.filter, .all)
        XCTAssertNil(vm.dayDone)

        vm.filter = .tracks
        vm.markDayDone("2026-10-22")

        XCTAssertEqual(defaults.string(forKey: "inbox.filter"), "tracks")
        XCTAssertEqual(defaults.string(forKey: "inbox.dayCardDone"), "2026-10-22")
        let next = makeVM()
        XCTAssertEqual(next.filter, .tracks)
        XCTAssertEqual(next.dayDone, "2026-10-22")
    }

    func testOpenSetsTheFilterAndSelects() async throws {
        let id = try await pool.write { try Self.message($0, 1) }
        let vm = makeVM()

        await vm.open(.messages, select: .message(id))

        XCTAssertEqual(vm.filter, .messages)
        XCTAssertEqual(vm.selection, .message(id))
        XCTAssertNotNil(try row("inbox_items", id)["read_at"] as String?)
    }

    func testShowOlderDaysReadsAnotherPage() async throws {
        try await pool.write { db in
            for day in 1...31 {
                try TestDatabase.insertBriefing(db, date: String(format: "2026-08-%02d", day))
            }
        }
        let vm = makeVM()
        vm.refresh()
        XCTAssertEqual(vm.feed.days.count, 30)

        vm.showOlderDays()

        XCTAssertEqual(vm.dayLimit, 60)
        XCTAssertEqual(vm.feed.days.count, 31)
    }

    // MARK: - Polling (board #731)

    func testPollSkipsWhileOffScreen() async throws {
        let vm = makeVM()
        vm.refresh()
        vm.setOnScreen(false)
        let id = try await pool.write { try Self.message($0, 1) }

        await vm.pollTick()
        XCTAssertTrue(vm.feed.messages.isEmpty)

        vm.setOnScreen(true)
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id], "back on screen after a skipped tick refreshes at once")
    }
}
