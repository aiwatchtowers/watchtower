import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox view model over every kind (C1 Task 5): one pure read
/// (STRIP-02 extended), the opening writes per kind, the track and message
/// buttons, the remembered day Done, the routes, and the on-screen poll.
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

    private func makeVM(_ runner: CLIRunnerProtocol = FakeCLIRunner()) -> ActionStripViewModel {
        ActionStripViewModel(dbPool: pool, cliRunner: runner, defaults: defaults)
    }

    /// The Go feed case `name` (`inbox_feed_cases.json`) seeded into the pool.
    private func tower(_ name: String) throws -> FeedCaseTransport {
        try FeedCaseTransport.seeded(name, pool: XCTUnwrap(pool))
    }

    /// The day the Go cases are built on (their `now`).
    private static let caseDay = "2026-11-16"

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
        // morning-brief's move failed; Go's next feed once the CLI marks it done.
        let tower = try tower("desktop_kinds_builtin_retry")
        let runner = FakeCLIRunner(stdout: Data(#"{"results":[{"builtin_id":"morning-brief","status":"done"}]}"#.utf8))
        let pool = try XCTUnwrap(pool)
        runner.onRun = { _ in
            // The CLI's own write, as Go `db.RecordBuiltinMigration` makes it.
            try? await pool.write { db in
                try db.execute(sql: "UPDATE builtin_migrations SET status = 'done', error = ''")
            }
        }
        let vm = makeVM(runner)
        await vm.follow(tower)
        XCTAssertEqual(vm.feed.builtinNotices.map(\.builtinID), ["morning-brief"], "the notice is read")
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
        let date = Self.caseDay
        // An output, its run's proposal, a due reminder, the day's briefing and
        // plan, a track with an event, an idea, a message and a failed move.
        let tower = try tower("desktop_kinds_every_source")
        let tables = [
            "briefings", "day_plans", "day_plan_items", "tracks", "track_events", "ideas", "inbox_items",
            "agent_actions", "reminders", "automation_outputs", "automation_runs", "automations", "pipeline_runs",
            "builtin_migrations"
        ]
        let before = try dump(tables)
        let vm = makeVM()

        await vm.follow(tower)
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
        let date = Self.caseDay
        // Briefings 1 (2026-01-01) and 2 (the case's day).
        let tower = try tower("desktop_kinds_two_briefings")
        let id = 2
        let other = try row("briefings", id - 1)
        let before = try row("briefings", id)
        let vm = makeVM()
        await vm.follow(tower)

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
        let tower = try tower("desktop_kinds_one_message")
        let id = 1
        let before = try row("inbox_items", id)
        let vm = makeVM()
        await vm.follow(tower)

        await vm.select(.message(id))

        let after = try row("inbox_items", id)
        XCTAssertNotNil(after["read_at"] as String?)
        XCTAssertNotEqual(after["read_at"] as String?, "")
        assertOnlyChanged("read_at", before: before, after: after)
        XCTAssertEqual(vm.feed.messages.map(\.item.isUnread), [false])
        XCTAssertNil(vm.lastError)
    }

    func testOpeningATrackWritesNothing() async throws {
        // Track 1 with an unread event, idea 1.
        let tower = try tower("desktop_kinds_track_and_idea")
        let id = 1
        let tables = ["tracks", "track_events", "ideas"]
        let before = try dump(tables)
        let vm = makeVM()
        await vm.follow(tower)
        let idea = try XCTUnwrap(vm.feed.ideas.first)

        await vm.select(.track(id))
        await vm.select(.idea(idea.id))

        XCTAssertEqual(try dump(tables), before)
        XCTAssertEqual(vm.selection, .idea(idea.id))
    }

    func testOpeningAnAlreadyReadCardWritesNothing() async throws {
        let date = Self.caseDay
        // The day's briefing and message 1, both read already.
        let tower = try tower("desktop_kinds_read_briefing_and_message")
        let id = 1
        let tables = ["briefings", "inbox_items"]
        let before = try dump(tables)
        let vm = makeVM()
        await vm.follow(tower)

        await vm.select(.day(date))
        await vm.select(.message(id))

        XCTAssertEqual(try dump(tables), before)
        XCTAssertNil(vm.lastError)
    }

    // MARK: - Tracks

    func testTrackDoneMarksTrackAndEventsRead() async throws {
        // Tracks 1 (two unread events) and 2 (one); Go's next feed once 1 is done.
        let tower = try tower("desktop_kinds_two_tracks_with_updates")
        let (id, other) = (1, 2)
        let vm = makeVM()
        await vm.follow(tower)

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
        // Custom track 1 (collecting) and auto track 2; Go's feeds once each is stopped.
        let tower = try tower("desktop_kinds_custom_and_auto_track")
        let (custom, auto) = (1, 2)
        let vm = makeVM()
        await vm.follow(tower)
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

    /// Approving a `create_track` proposal (C3 ruling): once it applied,
    /// its track is watched (`tracks start`); a refused start shows on the
    /// card and leaves the track unbound, so it keeps **Start Watching**.
    func testApprovedCreateTrackStartsWatching() async throws {
        for refused in [false, true] {
            let (actionID, trackID) = try await pool.write { db -> (Int64, Int) in
                let track = Int(try TestDatabase.insertTrack(db, text: "Watch the refund"))
                try db.execute(sql: "UPDATE tracks SET origin = 'custom' WHERE id = ?", arguments: [track])
                let action = try TestDatabase.insertAgentAction(
                    db, tool: "create_track", argsJSON: #"{"text":"Watch the refund"}"#, contextType: "reaction")
                return (action, track)
            }
            let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"track_id":\#(trackID),"automation_id":9}"#.utf8))
            let pool = try XCTUnwrap(pool)
            let refusal = "confirm this watch in Automations first"
            runner.onRun = { [weak runner] args in
                if args.count > 1, args[1] == "approve" {
                    try? await pool.write { db in
                        try db.execute(sql: "UPDATE agent_actions SET status = 'applied', result_json = ? WHERE id = ?",
                                       arguments: [#"{"track_id":\#(trackID)}"#, actionID])
                    }
                } else if refused, args.first == "tracks" {
                    runner?.shouldThrow = CLIRunnerError.nonZeroExit(code: 1, stderr: refusal + "\n")
                }
            }
            let vm = makeVM(runner)

            await vm.approve(actionID, shownArgs: #"{"text":"Watch the refund"}"#)

            let calls = runner.invocations
            XCTAssertEqual(calls.count, 2, "refused: \(refused)")
            XCTAssertEqual(Array(calls[0].prefix(3)), ["actions", "approve", String(actionID)])
            XCTAssertEqual(calls[1], ["tracks", "start", String(trackID), "--json"])
            let error = vm.actionFeed.rowErrors[actionID]
            if refused {
                XCTAssertEqual(error?.verb, AgentActionFeed.startVerb)
                XCTAssertEqual(error?.message, AgentActionFeed.notWatchedPrefix + refusal)
            } else {
                XCTAssertNil(error)
            }
        }

        // A proposal of another tool, or one that did not apply, starts nothing.
        let other = try await pool.write { db in try TestDatabase.insertAgentAction(db, tool: "create_target") }
        let quiet = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))
        await makeVM(quiet).approve(other, shownArgs: #"{"text":"Call Vasya","reason":"r"}"#)
        XCTAssertEqual(quiet.invocations.count, 1)
        let pendingTrack = try await pool.write { db in
            try TestDatabase.insertAgentAction(db, tool: "create_track", argsJSON: #"{"text":"x"}"#)
        }
        let stays = FakeCLIRunner(stdout: Data(#"{"ok":true}"#.utf8))
        await makeVM(stays).approve(pendingTrack, shownArgs: #"{"text":"x"}"#)
        XCTAssertEqual(stays.invocations.count, 1, "still pending: nothing applied, nothing to watch")
    }

    /// **Retry** of a failed `create_track` that then applies starts its
    /// watch too, under the same guards as Approve.
    func testRetriedCreateTrackStartsWatching() async throws {
        let (actionID, trackID) = try await pool.write { db -> (Int64, Int) in
            let track = Int(try TestDatabase.insertTrack(db, text: "Watch the refund"))
            try db.execute(sql: "UPDATE tracks SET origin = 'custom' WHERE id = ?", arguments: [track])
            let action = try TestDatabase.insertAgentAction(
                db, tool: "create_track", argsJSON: #"{"text":"Watch the refund"}"#, status: "failed", error: "busy")
            return (action, track)
        }
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"track_id":\#(trackID),"automation_id":9}"#.utf8))
        let pool = try XCTUnwrap(pool)
        runner.onRun = { args in
            guard args.count > 1, args[1] == "apply" else { return }
            try? await pool.write { db in
                try db.execute(sql: "UPDATE agent_actions SET status = 'applied', error = '', result_json = ? WHERE id = ?",
                               arguments: [#"{"track_id":\#(trackID)}"#, actionID])
            }
        }
        let vm = makeVM(runner)

        await vm.retry(actionID)

        XCTAssertEqual(runner.invocations.map { Array($0.prefix(2)) }, [["actions", "apply"], ["tracks", "start"]])
        XCTAssertEqual(runner.invocations.last, ["tracks", "start", String(trackID), "--json"])
        XCTAssertNil(vm.actionFeed.rowErrors[actionID])
    }

    // MARK: - Messages

    func testMessageButtonsRunTheInboxCLI() async throws {
        let tower = try tower("desktop_kinds_one_message")
        let id = 1
        let runner = FakeCLIRunner()
        let vm = makeVM(runner)
        await vm.follow(tower)

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
        let tower = try tower("desktop_kinds_one_message")
        let id = 1
        let vm = makeVM(FakeCLIRunner(error: CLIRunnerError.binaryNotFound))
        await vm.follow(tower)

        await vm.messageDone(id)

        XCTAssertEqual(vm.lastError, CLIRunnerError.binaryNotFound.localizedDescription)
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id])
    }

    func testMessageDoneOnAResolvedItemIsQuiet() async throws {
        // Message 1; Go's next feed once INBOX-02 resolved it.
        let tower = try tower("desktop_kinds_message_resolved_elsewhere")
        let id = 1
        let vm = makeVM()
        await vm.follow(tower)
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
        // Messages 1–3, newest first; Go's feeds once 2 and 3, then 1, are resolved.
        let tower = try tower("desktop_kinds_selected_message_vanishes")
        let ids = [1, 2, 3]
        let vm = makeVM()
        await vm.follow(tower)
        vm.openLegacy(.messages)
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
        // Messages 1–3, newest first; Go's feed once 2 is resolved.
        let tower = try tower("desktop_kinds_selected_message_resolved")
        let ids = [1, 2, 3]
        let vm = makeVM()
        await vm.follow(tower)
        vm.openLegacy(.messages)
        await vm.select(.message(ids[1]))
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [ids[1]])
        }

        await vm.pollTick()

        XCTAssertEqual(vm.selection, .message(ids[2]))
    }

    func testOverlappingRefreshesEachEndOnAFreshRead() async throws {
        // The tower already lists message 1 (its read saw the write first);
        // the panes' records read decides when its row shows.
        let tower = try FeedCaseTransport("desktop_kinds_one_message", pool: XCTUnwrap(pool))
        try tower.seedFolders()
        let vm = makeVM()
        await vm.follow(tower)
        async let first: Void = vm.refresh()
        let id = try await pool.write { try Self.message($0, 1) }
        async let second: Void = vm.refresh()
        _ = await (first, second)

        // The second call started after the write: it returns only after a read that sees it.
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id])
        XCTAssertNil(vm.lastError)
    }

    // MARK: - Per-viewer state

    /// Ask #607: the day card has no Done any more, so opening, reading and
    /// leaving one never writes the old per-viewer key.
    func testDayCardDoneIsNeverWritten() async {
        let vm = makeVM()
        await vm.refresh()
        await vm.select(.day("2026-10-22"))
        await vm.select(nil)
        await vm.refresh()

        XCTAssertNil(defaults.object(forKey: "inbox.dayCardDone"))
        XCTAssertNil(defaults.object(forKey: "inbox.filter"), "the filter bar's key is gone")
    }

    func testOpenShowsTheListAndSelects() async throws {
        let tower = try tower("desktop_kinds_one_message")
        let id = 1
        let vm = makeVM()
        await vm.follow(tower)

        await vm.open(folder: nil, select: .card(.message(id)))

        XCTAssertEqual(vm.legacyList, .messages)
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

        await vm.open(folder: nil, select: .card(.message(id)))

        XCTAssertEqual(vm.legacyList, .messages)
        XCTAssertNil(vm.selection)
        XCTAssertNil(try row("inbox_items", id)["read_at"] as String?)
    }

    /// A link to a stopped track opens the Stopped fold and selects it; a
    /// link to a merged idea selects the idea it was merged into; a card
    /// that is nowhere selects nothing (never a pane the next poll empties).
    func testOpeningAHiddenTrackOrIdeaSelectsWhatIsListed() async throws {
        // Track 1 stopped; idea 2 merged into idea 1.
        let tower = try tower("desktop_kinds_stopped_track_and_merged_idea")
        let (stopped, target, merged) = (1, 1, 2)
        let vm = makeVM()
        await vm.follow(tower)

        await vm.open(folder: nil, select: .card(.track(stopped)))
        XCTAssertTrue(vm.showsStopped, "the Stopped fold opens")
        XCTAssertEqual(vm.selection, .track(stopped))

        await vm.open(folder: nil, select: .card(.idea(merged)))
        XCTAssertEqual(vm.selection, .idea(target), "the merge target opens")

        await vm.open(folder: nil, select: .card(.idea(9999)))
        XCTAssertNil(vm.selection)
        await vm.open(folder: nil, select: .card(.track(9999)))
        XCTAssertNil(vm.selection)
    }

    // MARK: - Polling (board #731)

    func testPollSkipsWhileOffScreen() async throws {
        // The tower already lists message 1; the panes' records read decides when it shows.
        let tower = try FeedCaseTransport("desktop_kinds_one_message", pool: XCTUnwrap(pool))
        try tower.seedFolders()
        let vm = makeVM()
        await vm.follow(tower)
        vm.setOnScreen(false)
        let id = try await pool.write { try Self.message($0, 1) }

        await vm.pollTick()
        XCTAssertTrue(vm.feed.messages.isEmpty)

        vm.setOnScreen(true)
        await vm.onScreenRefresh?.value
        XCTAssertEqual(vm.feed.messages.map(\.item.id), [id], "back on screen after a skipped tick refreshes at once")
    }
}
