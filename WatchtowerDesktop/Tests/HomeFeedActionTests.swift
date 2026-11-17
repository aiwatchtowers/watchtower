import XCTest
import GRDB
import Observation
import os
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// A performer that records each call, may wait for `release()` and may
/// run a DB write or throw.
@MainActor
final class FakeHomeFeedPerformer: HomeFeedPerforming {
    private(set) var calls: [(FeedAction, FeedRef)] = []
    var gated = false
    var error: Error?
    var write: ((FeedAction, FeedRef) async throws -> Void)?
    private var gate: CheckedContinuation<Void, Never>?

    /// What the next calls return when they do not throw.
    var written = true

    func perform(_ action: FeedAction, on ref: FeedRef, contentHash: String, now: Date, calendar: Calendar)
        async throws -> Bool {
        calls.append((action, ref))
        if gated { await withCheckedContinuation { gate = $0 } }
        if let error { throw error }
        try await write?(action, ref)
        return written
    }

    var isWaiting: Bool { gate != nil }

    func release() {
        gate?.resume()
        gate = nil
    }
}

/// Holds each row's write until `release(_:failing:)` for that row, so two
/// Done / Hide presses can overlap and land in either order.
@MainActor
private final class PerRowGatedPerformer: HomeFeedPerforming {
    private var gates: [FeedRef: CheckedContinuation<Error?, Never>] = [:]

    func perform(_ action: FeedAction, on ref: FeedRef, contentHash: String, now: Date, calendar: Calendar)
        async throws -> Bool {
        if let error = await withCheckedContinuation({ gates[ref] = $0 }) { throw error }
        return true
    }

    func isWaiting(_ ref: FeedRef) -> Bool { gates[ref] != nil }

    func release(_ ref: FeedRef, failing error: Error? = nil) {
        gates.removeValue(forKey: ref)?.resume(returning: error)
    }
}

/// Records each CLI call and its timeout (nil for the untimed call);
/// answers with empty stdout or throws `error`.
private final class RecordingRunner: CLIRunnerProtocol, @unchecked Sendable {
    private(set) var calls: [[String]] = []
    private(set) var timeouts: [TimeInterval?] = []
    var error: Error?

    func run(args: [String]) async throws -> Data {
        try record(args, timeout: nil)
    }

    func run(args: [String], timeout: TimeInterval) async throws -> Data {
        try record(args, timeout: timeout)
    }

    private func record(_ args: [String], timeout: TimeInterval?) throws -> Data {
        calls.append(args)
        timeouts.append(timeout)
        if let error { throw error }
        return Data()
    }
}

private struct PerformerFailure: LocalizedError {
    var errorDescription: String? { "watchtower exited with error: database is locked" }
}

@MainActor
final class HomeFeedActionTests: XCTestCase {
    private var poolPaths: [String] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        suiteNames.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        suiteNames = []
        super.tearDown()
    }

    private func makePool() throws -> DatabasePool {
        let (pool, path) = try TestDatabase.createPool()
        poolPaths.append(path)
        return pool
    }

    private func makeCenter(performer: any HomeFeedPerforming) throws -> HomeCenter {
        let name = "HomeFeedActionTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        return HomeCenter(readiness: ReadinessCenter(environment: FakeReadinessEnvironment()),
                          environment: FakeHomeEnvironment(),
                          store: GettingReadyStore(defaults: defaults),
                          performer: performer)
    }

    /// Waits until `condition` holds for the center's snapshot, re-checking
    /// on every change of it — no deadline.
    private func waitUntil(_ center: HomeCenter, _ condition: @escaping (HomeSnapshot?) -> Bool) async {
        await untilObserved { condition(center.snapshot) }
    }

    private func shows(_ ref: FeedRef) -> (HomeSnapshot?) -> Bool {
        { $0?.feed.waiting.contains { $0.id == ref } == true }
    }

    private func hides(_ ref: FeedRef) -> (HomeSnapshot?) -> Bool {
        { $0 != nil && $0?.feed.waiting.contains { $0.id == ref } == false }
    }

    private func insertMention(_ pool: DatabasePool) throws -> FeedRef {
        let id = try pool.write { db in try TestDatabase.insertInboxItem(db) }
        return .inbox(Int(id))
    }

    private func resolve(_ pool: DatabasePool, _ ref: FeedRef) async throws {
        guard case .inbox(let id) = ref else { return }
        try await pool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved' WHERE id = ?", arguments: [id])
        }
    }

    private func insertReminder(_ pool: DatabasePool) throws -> Int64 {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO reminders (message_ref, note, remind_at, status)
                VALUES ('C1@1', 'call Ann', '2000-01-01T00:00:00Z', 'pending')
                """)
            return db.lastInsertedRowID
        }
    }

    /// Spring-forward-safe fixed clock: Monday 2026-10-19 12:00 UTC in Berlin (CEST).
    private func berlin() throws -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
        return (now, calendar)
    }

    // MARK: - HomeCenter

    func testDoneHidesAtOnceThenStaysGone() async throws {
        let pool = try makePool()
        let ref = try insertMention(pool)
        let performer = FakeHomeFeedPerformer()
        performer.gated = true
        performer.write = { _, _ in try await self.resolve(pool, ref) }
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))

        let task = Task { await center.act(.done, on: ref) }
        await waitUntil(center, hides(ref))
        XCTAssertEqual(performer.calls.count, 1)
        XCTAssertTrue(performer.isWaiting, "the row left before the performer returned")

        performer.release()
        await task.value
        XCTAssertFalse(shows(ref)(center.snapshot))
        XCTAssertNil(center.feedErrors[ref])
        XCTAssertFalse(center.hiddenRefs.contains(ref), "the re-read no longer returns it")
    }

    func testCLIFailureBringsTheRowBack() async throws {
        let pool = try makePool()
        let ref = try insertMention(pool)
        let performer = FakeHomeFeedPerformer()
        performer.error = PerformerFailure()
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))

        await center.act(.done, on: ref)
        XCTAssertTrue(shows(ref)(center.snapshot))
        XCTAssertEqual(center.feedErrors[ref], "watchtower exited with error: database is locked")
        XCTAssertFalse(center.hiddenRefs.contains(ref))
    }

    /// An automation output reaches the feed from the database, and a failed
    /// Done keeps its error once the next read lands (HomeCenter.contains).
    func testAutomationOutputFailureBringsTheRowBack() async throws {
        let pool = try makePool()
        let id = try await pool.write { db -> Int64 in
            let automation = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            return try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run,
                createdAt: AutomationDates.format(Date().addingTimeInterval(-60)))
        }
        let ref = FeedRef.output(id)
        let performer = FakeHomeFeedPerformer()
        performer.error = PerformerFailure()
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))

        await center.act(.done, on: ref)
        await center.rereadNow()
        XCTAssertTrue(shows(ref)(center.snapshot))
        XCTAssertEqual(center.feedErrors[ref], "watchtower exited with error: database is locked")
        XCTAssertFalse(center.hiddenRefs.contains(ref))
    }

    /// Done on a living card rewritten since the feed drew it writes
    /// nothing (the drawn hash no longer matches): the row comes back with
    /// no error, and the re-read shows the new version.
    func testDoneOnACardRewrittenUnderTheViewBringsItBack() async throws {
        let pool = try makePool()
        let stamp = AutomationDates.format(Date().addingTimeInterval(-60))
        let (automation, id) = try await pool.write { db -> (Int64, Int64) in
            let automation = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            return (automation, try TestDatabase.insertAutomationOutput(
                db, automationID: automation, runID: run, createdAt: stamp, outputKey: "threads", contentHash: "h1"))
        }
        let ref = FeedRef.output(id)
        let tower = FakeScreenTower()
        tower.next(.outputsDone, .ok(#"{"already":true}"#))
        let center = try makeCenter(performer: LiveHomeFeedPerformer(runner: nil, tower: tower))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))
        try await pool.write { db in
            let run = try TestDatabase.insertAutomationRun(db, automationID: automation)
            try TestDatabase.rewriteLivingOutput(db, id: id, runID: run, body: "new", blocksJSON: "",
                                                 contentHash: "h2", at: AutomationDates.format(Date()))
        }

        await center.act(.done, on: ref)
        XCTAssertEqual(tower.calls.first?.params["content_hash"] as? String, "h1", "guarded by the version drawn")
        XCTAssertTrue(shows(ref)(center.snapshot))
        XCTAssertNil(center.feedErrors[ref])
        XCTAssertFalse(center.hiddenRefs.contains(ref))
        let doneAt = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT done_at FROM automation_outputs WHERE id = ?", arguments: [id])
        }
        XCTAssertNil(doneAt)
    }

    func testASecondPressClearsTheRowsError() async throws {
        let pool = try makePool()
        let ref = try insertMention(pool)
        let performer = FakeHomeFeedPerformer()
        performer.error = PerformerFailure()
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))
        await center.act(.done, on: ref)
        XCTAssertNotNil(center.feedErrors[ref])

        performer.error = nil
        performer.write = { _, _ in try await self.resolve(pool, ref) }
        await center.act(.done, on: ref)
        XCTAssertNil(center.feedErrors[ref])
        XCTAssertFalse(shows(ref)(center.snapshot))
    }

    /// Go's `ResolveInboxItem` / `DismissInboxItem` do not check the rows
    /// they changed: a missing or already resolved item exits 0. Home takes
    /// that success at its word — no error, the row stays gone.
    func testDoneOnAnAlreadyResolvedItemIsQuiet() async throws {
        let pool = try makePool()
        let ref = try insertMention(pool)
        let runner = RecordingRunner()
        let center = try makeCenter(performer: LiveHomeFeedPerformer(runner: runner, tower: FakeScreenTower()))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))
        // Closed by another process: the observation never sees it, the snapshot still shows the row.
        let elsewhere = try DatabaseQueue(path: try XCTUnwrap(poolPaths.last))
        try await elsewhere.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'resolved'")
        }
        try elsewhere.close()
        XCTAssertTrue(shows(ref)(center.snapshot))

        await center.act(.done, on: ref)
        guard case .inbox(let id) = ref else { return XCTFail("not an inbox ref") }
        XCTAssertEqual(runner.calls, [["inbox", "resolve", "\(id)"]])
        XCTAssertNil(center.feedErrors[ref])
        XCTAssertFalse(shows(ref)(center.snapshot))
        XCTAssertFalse(center.hiddenRefs.contains(ref))
    }

    /// Done / Hide on a kind that has neither (a proposal, an event) does
    /// nothing: no hide, no write.
    func testActOnAKindWithoutActionsDoesNothing() async throws {
        let pool = try makePool()
        let id = try await pool.write { db in try TestDatabase.insertAgentAction(db) }
        let ref = FeedRef.proposal(id)
        let performer = FakeHomeFeedPerformer()
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))

        await center.act(.hide, on: ref)
        await center.act(.done, on: .event("e1"))
        XCTAssertTrue(performer.calls.isEmpty)
        XCTAssertTrue(center.hiddenRefs.isEmpty)
        XCTAssertTrue(shows(ref)(center.snapshot))
    }

    /// The inbox CLI call is bounded: a timeout is an error like any other,
    /// and the row comes back with it.
    func testInboxTimeoutBringsTheRowBack() async throws {
        let pool = try makePool()
        let ref = try insertMention(pool)
        let runner = RecordingRunner()
        runner.error = CLIRunnerError.nonZeroExit(code: -1, stderr: "timed out after 30s")
        let center = try makeCenter(performer: LiveHomeFeedPerformer(runner: runner, tower: FakeScreenTower()))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))

        await center.act(.hide, on: ref)
        XCTAssertEqual(runner.timeouts, [30])
        XCTAssertTrue(shows(ref)(center.snapshot))
        XCTAssertEqual(center.feedErrors[ref], "watchtower exited with error: timed out after 30s")
        XCTAssertFalse(center.hiddenRefs.contains(ref))
    }

    private func insertInbox(_ pool: DatabasePool, count: Int) async throws {
        try await pool.write { db in
            for index in 0..<count {
                try TestDatabase.insertInboxItem(db, messageTS: String(format: "1700000000.%06d", index))
            }
        }
    }

    /// Over a long backlog the feed pages in place: seven, 50, 100, the last
    /// partial page, and Show less goes back to seven.
    func testPageFeedPagesAndShowsLess() async throws {
        let pool = try makePool()
        try await insertInbox(pool, count: 120)
        let center = try makeCenter(performer: FakeHomeFeedPerformer())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.feed.waiting.count == 7 }
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 113)

        center.pageFeed(more: true)
        XCTAssertEqual(center.feedLimit, 50)
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 50)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 70)

        center.pageFeed(more: true)
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 100)
        center.pageFeed(more: true)
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 120)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 0)

        center.pageFeed(more: false)
        XCTAssertEqual(center.feedLimit, HomeFeedBuilder.waitingLimit)
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 7)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 113)
    }

    /// Done / Hide down to seven rows or fewer collapses the page state, so
    /// the next backlog starts folded instead of expanded with no Show less.
    func testFeedCollapsesWhenRowsDropToSeven() async throws {
        let pool = try makePool()
        try await insertInbox(pool, count: 9)
        let center = try makeCenter(performer: FakeHomeFeedPerformer())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.feed.waiting.count == 7 }

        center.pageFeed(more: true)
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 9)
        let refs = try XCTUnwrap(center.snapshot?.feed.waiting.prefix(2).map(\.id))
        await center.act(.done, on: refs[0])
        XCTAssertEqual(center.feedLimit, 50, "eight rows: still expanded")
        await center.act(.done, on: refs[1])
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 7)
        XCTAssertEqual(center.feedLimit, HomeFeedBuilder.waitingLimit)
    }

    /// A Done that fails while the list is expanded at eight rows: the
    /// page does not collapse under the pending write, so the row comes
    /// back with its error in view, not behind "1 more".
    func testFailedDoneKeepsThePageOpen() async throws {
        let pool = try makePool()
        try await insertInbox(pool, count: 8)
        let performer = FakeHomeFeedPerformer()
        performer.gated = true
        performer.error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "write failed"])
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.feed.waiting.count == 7 }
        center.pageFeed(more: true)
        let ref = try XCTUnwrap(center.snapshot?.feed.waiting.last?.id)

        let done = Task { await center.act(.done, on: ref) }
        await waitUntil(center, hides(ref))
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 7)
        XCTAssertEqual(center.feedLimit, 50, "no collapse while the write runs")
        XCTAssertTrue(performer.isWaiting)
        performer.release()
        await done.value

        XCTAssertEqual(center.feedErrors[ref], "write failed")
        XCTAssertTrue(shows(ref)(center.snapshot), "the failed row is back in view")
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 8)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 0)
        XCTAssertEqual(center.feedLimit, 50)
    }

    /// Two overlapping Done presses on an expanded list of nine: the first
    /// landing leaves the page open while the second still runs; the
    /// second landing collapses it when seven rows are left.
    func testOverlappingDonesCollapseOnlyOnceBothLand() async throws {
        let (center, performer, first, second) = try await startTwoDones()
        defer { center.endReading() }
        performer.release(second.ref)
        await second.task.value
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 7)
        XCTAssertEqual(center.feedLimit, 50, "the first Done still runs")

        performer.release(first.ref)
        await first.task.value
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 7)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 0)
        XCTAssertEqual(center.feedLimit, HomeFeedBuilder.waitingLimit)
    }

    /// The same overlap, the later write failing: its row comes back with
    /// the error, eight rows, and the page stays open.
    func testOverlappingDoneFailureKeepsThePageOpen() async throws {
        let (center, performer, first, second) = try await startTwoDones()
        defer { center.endReading() }
        performer.release(first.ref)
        await first.task.value
        XCTAssertEqual(center.feedLimit, 50, "the second Done still runs")

        performer.release(
            second.ref, failing: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "write failed"]))
        await second.task.value
        XCTAssertEqual(center.feedErrors[second.ref], "write failed")
        XCTAssertTrue(shows(second.ref)(center.snapshot))
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 8)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 0)
        XCTAssertEqual(center.feedLimit, 50)
    }

    /// Nine rows, expanded, Done pressed on two of them with both writes held.
    private func startTwoDones() async throws -> (
        HomeCenter, PerRowGatedPerformer, (ref: FeedRef, task: Task<Void, Never>), (ref: FeedRef, task: Task<Void, Never>)
    ) {
        let pool = try makePool()
        try await insertInbox(pool, count: 9)
        let performer = PerRowGatedPerformer()
        let center = try makeCenter(performer: performer)
        center.beginReading(pool: pool)
        await waitUntil(center) { $0?.feed.waiting.count == 7 }
        center.pageFeed(more: true)
        let refs = try XCTUnwrap(center.snapshot?.feed.waiting.prefix(2).map(\.id))
        let first = Task { await center.act(.done, on: refs[0]) }
        await waitUntil(center, hides(refs[0]))
        let second = Task { await center.act(.done, on: refs[1]) }
        await waitUntil(center, hides(refs[1]))
        XCTAssertTrue(performer.isWaiting(refs[0]))
        XCTAssertTrue(performer.isWaiting(refs[1]))
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 7)
        XCTAssertEqual(center.feedLimit, 50, "no collapse while both run")
        return (center, performer, (refs[0], first), (refs[1], second))
    }

    // MARK: - LiveHomeFeedPerformer

    /// The calls `tower` got, as "command id[ until]".
    private func sent(_ tower: FakeScreenTower) -> [String] {
        tower.calls.map { call in
            let id = (call.params["id"] as? Int).map(String.init) ?? ""
            let extra = (call.params["until"] as? String) ?? (call.params["status"] as? String)
                ?? (call.params["content_hash"] as? String)
            return "\(call.command.rawValue) \(id)" + (extra.map { " \($0)" } ?? "")
        }
    }

    /// Done is `outputs.done`, Hide `outputs.dismiss`, both at the drawn
    /// hash; Go's guarded no-op (`already`) reads as "nothing written".
    func testAutomationOutputDoneMarksDoneAndHideDismisses() async throws {
        let runner = RecordingRunner()
        let tower = FakeScreenTower()
        tower.next(.outputsDismiss, .ok("{}"))
        tower.next(.outputsDismiss, .ok(#"{"already":true}"#))
        let performer = LiveHomeFeedPerformer(runner: runner, tower: tower)
        let done = try await performer.perform(.done, on: .output(1), contentHash: "h1", now: Date(), calendar: .current)
        let hidden = try await performer.perform(.hide, on: .output(2), contentHash: "h2", now: Date(), calendar: .current)
        let again = try await performer.perform(.hide, on: .output(1), contentHash: "h1", now: Date(), calendar: .current)
        XCTAssertEqual(sent(tower), ["outputs.done 1 h1", "outputs.dismiss 2 h2", "outputs.dismiss 1 h1"])
        XCTAssertEqual([done, hidden, again], [true, true, false])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testInboxDoneRunsResolve() async throws {
        let runner = RecordingRunner()
        let tower = FakeScreenTower()
        let performer = LiveHomeFeedPerformer(runner: runner, tower: tower)
        try await performer.perform(.done, on: .inbox(1), contentHash: "", now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .inbox(1), contentHash: "", now: Date(), calendar: .current)
        XCTAssertEqual(runner.calls, [["inbox", "resolve", "1"], ["inbox", "dismiss", "1"]])
        XCTAssertEqual(runner.timeouts, [30, 30])
        XCTAssertTrue(tower.calls.isEmpty)
    }

    /// A non-zero exit is a real failure (Go has no "not found" exit for these).
    func testInboxNonZeroExitThrows() async throws {
        let runner = RecordingRunner()
        runner.error = CLIRunnerError.nonZeroExit(code: 1, stderr: "resolving inbox item 1: database is locked")
        let performer = LiveHomeFeedPerformer(runner: runner, tower: FakeScreenTower())
        do {
            try await performer.perform(.done, on: .inbox(1), contentHash: "", now: Date(), calendar: .current)
            XCTFail("expected the CLI error")
        } catch let error as CLIRunnerError {
            guard case .nonZeroExit(1, _) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testNoCLIIsAnError() async throws {
        let performer = LiveHomeFeedPerformer(runner: nil, tower: FakeScreenTower())
        do {
            try await performer.perform(.done, on: .inbox(1), contentHash: "", now: Date(), calendar: .current)
            XCTFail("expected cliUnavailable")
        } catch let error as HomeFeedActionError {
            XCTAssertEqual(error, .cliUnavailable)
        }
    }

    func testReminderHideSnoozesToTomorrowNine() async throws {
        let (now, calendar) = try berlin()
        let tower = FakeScreenTower()
        try await LiveHomeFeedPerformer(runner: nil, tower: tower)
            .perform(.hide, on: .reminder(7), contentHash: "", now: now, calendar: calendar)
        // Tuesday 09:00 CEST (UTC+2).
        XCTAssertEqual(sent(tower), ["reminders.snooze 7 2026-10-20T07:00:00Z"])
    }

    /// Done is `reminders.done`; Go runs Needs approval's redraw
    /// (`inbox approvals changed`) in the same call, so the Mac runs no CLI.
    func testReminderDoneMarksDone() async throws {
        let runner = FakeCLIRunner()
        let tower = FakeScreenTower()
        try await LiveHomeFeedPerformer(runner: runner, tower: tower)
            .perform(.done, on: .reminder(7), contentHash: "", now: Date(), calendar: .current)
        XCTAssertEqual(sent(tower), ["reminders.done 7"])
        XCTAssertTrue(runner.invocations.isEmpty)
    }

    func testTargetDoneAndHide() async throws {
        let tower = FakeScreenTower()
        tower.always(.targetsSetStatus, .ok(#"{"rolled_up":[]}"#))
        tower.always(.targetsSnooze, .ok(#"{"rolled_up":[]}"#))
        let (now, calendar) = try berlin()
        let performer = LiveHomeFeedPerformer(runner: nil, tower: tower)
        try await performer.perform(.done, on: .target(1), contentHash: "", now: now, calendar: calendar)
        try await performer.perform(.hide, on: .target(2), contentHash: "", now: now, calendar: calendar)
        XCTAssertEqual(sent(tower), ["targets.set_status 1 done", "targets.snooze 2 2026-10-20T07:00"])
    }

    /// Hide brings a target back tomorrow 09:00 local: `snooze_until` holds
    /// that instant as a UTC minute, which Go's `UnsnoozeExpiredTargets`
    /// compares against — a bare date would come back at 00:00 UTC, the
    /// same evening west of UTC.
    func testTargetHideSnoozesToTomorrowNineLocal() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
        for (zone, expected) in [("America/Los_Angeles", "2026-10-20T16:00"), ("Europe/Berlin", "2026-10-20T07:00")] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let tower = FakeScreenTower()
            tower.always(.targetsSnooze, .ok(#"{"rolled_up":[]}"#))
            try await LiveHomeFeedPerformer(runner: nil, tower: tower)
                .perform(.hide, on: .target(1), contentHash: "", now: now, calendar: calendar)
            XCTAssertEqual(sent(tower), ["targets.snooze 1 \(expected)"], zone)
        }
    }

    /// Go's `not_found` on a reminder or target deleted elsewhere is quiet:
    /// the row the owner wanted gone is gone.
    func testAReminderOrTargetGoneElsewhereIsQuiet() async throws {
        let tower = FakeScreenTower()
        for command in [TowerCommand.remindersSnooze, .targetsSetStatus, .targetsSnooze] {
            tower.always(command, .refused("Couldn't do that: it's no longer on the Mac."))
        }
        let performer = LiveHomeFeedPerformer(runner: nil, tower: tower)
        try await performer.perform(.hide, on: .reminder(999), contentHash: "", now: Date(), calendar: .current)
        try await performer.perform(.done, on: .target(999), contentHash: "", now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .target(999), contentHash: "", now: Date(), calendar: .current)
    }

    func testProposalAndEventAreNoOps() async throws {
        let runner = RecordingRunner()
        let tower = FakeScreenTower()
        let performer = LiveHomeFeedPerformer(runner: runner, tower: tower)
        try await performer.perform(.done, on: .proposal(1), contentHash: "", now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .event("e1"), contentHash: "", now: Date(), calendar: .current)
        XCTAssertEqual(runner.calls, [])
        XCTAssertTrue(tower.calls.isEmpty)
    }
}
