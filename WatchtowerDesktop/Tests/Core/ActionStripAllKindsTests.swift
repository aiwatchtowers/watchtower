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

    // MARK: - A built-in's failed move (C2)

    /// **Retry** runs `upgrade-builtins`, restarts the daemon once a move
    /// landed, and the card leaves when the next read finds it done; the
    /// Desktop writes no row itself (STRIP-02).
    func testRetryBuiltinUpgradeRunsTheCLIRestartsAndRereads() async throws {
        try await pool.write { db in
            try db.execute(sql: """
                INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at)
                VALUES ('morning-brief', 'failed', 'config unreadable', 1, '2026-10-22T07:00:00Z')
                """)
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"results":[{"builtin_id":"morning-brief","status":"done"}]}"#.utf8))
        let pool = try XCTUnwrap(pool)
        runner.onRun = { _ in
            // The CLI's own write, as Go `db.RecordBuiltinMigration` makes it.
            try? await pool.write { db in
                try db.execute(sql: "UPDATE builtin_migrations SET status = 'done', error = ''")
            }
        }
        let vm = makeVM(runner)
        await vm.refresh()
        XCTAssertEqual(vm.sections.first?.items.first?.id, .builtinNotice("morning-brief"))
        var restarts = 0

        await vm.retryBuiltinUpgrade("morning-brief") { restarts += 1 }

        XCTAssertEqual(runner.invocations, [["automations", "upgrade-builtins", "--json"]])
        XCTAssertEqual(restarts, 1)
        XCTAssertEqual(vm.feed.builtinNotices, [])
        XCTAssertNil(vm.lastError)
    }

    func testRetryBuiltinUpgradeThatFailsAgainDoesNotRestart() async throws {
        let runner = FakeCLIRunner(
            stdout: Data(#"{"results":[{"builtin_id":"morning-brief","status":"failed","error":"still locked"}]}"#.utf8))
        let vm = makeVM(runner)
        var restarts = 0
        await vm.retryBuiltinUpgrade("morning-brief") { restarts += 1 }
        XCTAssertEqual(restarts, 0, "nothing moved, so the old phase keeps running")

        runner.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        await vm.retryBuiltinUpgrade("morning-brief") { restarts += 1 }
        XCTAssertEqual(restarts, 0)
        XCTAssertEqual(vm.lastError, "boom")
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
            try db.execute(sql: """
                INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at)
                VALUES ('morning-brief', 'failed', 'config unreadable', 1, '2026-10-22T07:00:00Z')
                """)
        }
        let tables = [
            "briefings", "day_plans", "day_plan_items", "tracks", "track_events", "ideas", "inbox_items",
            "agent_actions", "reminders", "automation_outputs", "automation_runs", "automations", "pipeline_runs",
            "builtin_migrations"
        ]
        let before = try dump(tables)
        let vm = makeVM()

        await vm.refresh()
        await vm.refresh()

        XCTAssertEqual(try dump(tables), before)
        XCTAssertNil(vm.lastError)
        XCTAssertEqual(vm.feed.proposals.count, 1)
        XCTAssertEqual(vm.feed.reminders.count, 1)
        XCTAssertEqual(vm.feed.outputs.count, 1)
        XCTAssertEqual(vm.feed.days.map(\.date), [date])
        XCTAssertEqual(vm.feed.tracks.count, 1)
        XCTAssertEqual(vm.feed.ideas.count, 1)
        XCTAssertEqual(vm.feed.messages.count, 1)
        XCTAssertEqual(vm.feed.builtinNotices.map(\.builtinID), ["morning-brief"])
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
        await vm.refresh()

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
        await vm.refresh()

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
        await vm.refresh()
        let idea = try XCTUnwrap(vm.feed.ideas.first)

        await vm.select(.track(id))
        await vm.select(.idea(idea.id))

        XCTAssertEqual(try dump(tables), before)
        XCTAssertEqual(vm.selection, .idea(idea.id))
    }

    func testOpeningAnAlreadyReadCardWritesNothing() async throws {
        let date = today
        let id = try await pool.write { db -> Int in
            try TestDatabase.insertBriefing(db, date: date, readAt: "2026-10-01T00:00:00Z")
            let id = try Self.message(db, 1)
            try db.execute(sql: "UPDATE inbox_items SET read_at = '2026-10-01T00:00:00Z' WHERE id = ?", arguments: [id])
            return id
        }
        let tables = ["briefings", "inbox_items"]
        let before = try dump(tables)
        let vm = makeVM()
        await vm.refresh()

        await vm.select(.day(date))
        await vm.select(.message(id))

        XCTAssertEqual(try dump(tables), before)
        XCTAssertNil(vm.lastError)
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
        await vm.refresh()

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
        await vm.refresh()
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
        await vm.refresh()

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
        await vm.refresh()

        await vm.messageDone(id)

        XCTAssertEqual(vm.lastError, CLIRunnerError.binaryNotFound.localizedDescription)
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id])
    }

    func testMessageDoneOnAResolvedItemIsQuiet() async throws {
        let id = try await pool.write { try Self.message($0, 1) }
        let vm = makeVM()
        await vm.refresh()
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
        await vm.refresh()
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
        await vm.refresh()
        await vm.select(.message(ids[1]))
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [ids[1]])
        }

        await vm.pollTick()

        XCTAssertEqual(vm.selection, .message(ids[2]))
    }

    func testOverlappingRefreshesEachEndOnAFreshRead() async throws {
        let vm = makeVM()
        async let first: Void = vm.refresh()
        let id = try await pool.write { try Self.message($0, 1) }
        async let second: Void = vm.refresh()
        _ = await (first, second)

        // The second call started after the write: it returns only after a read that sees it.
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id])
        XCTAssertNil(vm.lastError)
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

    /// A route to a message no longer listed (resolved meanwhile) selects
    /// nothing and writes no read mark.
    func testOpenOnAMessageNoLongerListedSelectsNothing() async throws {
        let id = try await pool.write { db -> Int in
            let id = try Self.message(db, 1)
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [id])
            return id
        }
        let vm = makeVM()

        await vm.open(.messages, select: .message(id))

        XCTAssertEqual(vm.filter, .messages)
        XCTAssertNil(vm.selection)
        XCTAssertNil(try row("inbox_items", id)["read_at"] as String?)
    }

    func testShowOlderDaysReadsAnotherPage() async throws {
        try await pool.write { db in
            for day in 1...31 {
                try TestDatabase.insertBriefing(db, date: String(format: "2026-08-%02d", day))
            }
        }
        let vm = makeVM()
        await vm.refresh()
        XCTAssertEqual(vm.feed.days.count, 30)
        XCTAssertTrue(vm.feed.hasOlderDays)

        await vm.showOlderDays().value

        XCTAssertEqual(vm.dayLimit, 60)
        XCTAssertEqual(vm.feed.days.count, 31)
        XCTAssertFalse(vm.feed.hasOlderDays, "nothing older left: Show older goes")
    }

    /// A route to a day past the loaded pages reads older pages until the
    /// day is listed; a day that is nowhere selects nothing.
    func testOpeningAnOldDayLoadsOlderPages() async throws {
        try await pool.write { db in
            for day in 1...31 {
                try TestDatabase.insertBriefing(db, date: String(format: "2026-08-%02d", day))
                try TestDatabase.insertBriefing(db, date: String(format: "2026-07-%02d", day))
            }
        }
        let vm = makeVM()

        await vm.open(.day, select: .day("2026-07-01"))
        XCTAssertEqual(vm.selection, .day("2026-07-01"))
        XCTAssertEqual(vm.dayLimit, 90)

        await vm.open(.day, select: .day("2020-01-01"))
        XCTAssertNil(vm.selection, "not found: nothing selected")
        XCTAssertFalse(vm.feed.hasOlderDays)
    }

    /// A link to a stopped track opens the Stopped fold and selects it; a
    /// link to a merged idea selects the idea it was merged into; a card
    /// that is nowhere selects nothing (never a pane the next poll empties).
    func testOpeningAHiddenTrackOrIdeaSelectsWhatIsListed() async throws {
        let (stopped, target, merged) = try await pool.write { db -> (Int, Int, Int) in
            let stopped = try TestDatabase.insertTrack(db, text: "Old vendor migration")
            try db.execute(sql: "UPDATE tracks SET dismissed_at = '2026-10-18T10:00:00Z' WHERE id = ?",
                           arguments: [stopped])
            let target = try TestDatabase.insertIdea(db, title: "Weekly digest")
            let merged = try TestDatabase.insertIdea(db, title: "Friday email", status: "merged",
                                                     mergedIntoID: Int(target))
            return (Int(stopped), Int(target), Int(merged))
        }
        let vm = makeVM()

        await vm.open(.tracks, select: .track(stopped))
        XCTAssertTrue(vm.showsStopped, "the Stopped fold opens")
        XCTAssertEqual(vm.selection, .track(stopped))

        await vm.open(.ideas, select: .idea(merged))
        XCTAssertEqual(vm.selection, .idea(target), "the merge target opens")

        await vm.open(.ideas, select: .idea(9999))
        XCTAssertNil(vm.selection)
        await vm.open(.tracks, select: .track(9999))
        XCTAssertNil(vm.selection)
    }

    /// A failed read stops the route's paging instead of looping.
    func testOpeningAnOldDayStopsOnAFailedRead() async throws {
        try await pool.write { db in
            for day in 1...31 {
                try TestDatabase.insertBriefing(db, date: String(format: "2026-08-%02d", day))
            }
        }
        let vm = makeVM()
        vm.filter = .day
        await vm.refresh()
        XCTAssertTrue(vm.feed.hasOlderDays)
        // Every later read fails on a column the day query orders by.
        try await pool.write { db in
            try db.execute(sql: "ALTER TABLE briefings RENAME COLUMN created_at TO created_at_gone")
        }

        await vm.open(.day, select: .day("2020-01-01"))

        XCTAssertNotNil(vm.lastError)
        XCTAssertNil(vm.selection)
        XCTAssertEqual(vm.dayLimit, ActionStripViewModel.dayPage, "no page asked for after the failed read")
    }

    /// Today with neither a brief nor a plan: its placeholder card is listed
    /// (All and Day) but the badge stays 0.
    func testTodaysPlaceholderIsListedButNeverCounted() async throws {
        let vm = makeVM()
        await vm.refresh()
        XCTAssertEqual(vm.sections, [], "no owner: All has no placeholder")
        try await pool.write { db in _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U1") }
        await vm.refresh()

        XCTAssertEqual(vm.sections.flatMap(\.items).map(\.id), [.day(today)])
        vm.filter = .day
        XCTAssertEqual(vm.sections.flatMap(\.items).map(\.id), [.day(today)])
        vm.filter = .messages
        XCTAssertEqual(vm.sections, [])
        let nowUTC = AutomationDates.format(Date())
        let badge = try await pool.read { try ActionStripViewModel.badgeCount($0, nowUTC: nowUTC) }
        XCTAssertEqual(badge, 0)
    }

    // MARK: - Polling (board #731)

    func testPollSkipsWhileOffScreen() async throws {
        let vm = makeVM()
        await vm.refresh()
        vm.setOnScreen(false)
        let id = try await pool.write { try Self.message($0, 1) }

        await vm.pollTick()
        XCTAssertTrue(vm.feed.messages.isEmpty)

        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id], "back on screen after a skipped tick refreshes at once")
    }
}
