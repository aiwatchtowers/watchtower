import XCTest
import GRDB
import Observation
@testable import WatchtowerDesktop
import WatchtowerCore
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

    func perform(_ action: FeedAction, on ref: FeedRef, now: Date, calendar: Calendar) async throws {
        calls.append((action, ref))
        if gated { await withCheckedContinuation { gate = $0 } }
        if let error { throw error }
        try await write?(action, ref)
    }

    var isWaiting: Bool { gate != nil }

    func release() {
        gate?.resume()
        gate = nil
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

    private func waitUntil(
        _ center: HomeCenter, timeout: TimeInterval = 5, _ condition: @escaping (HomeSnapshot?) -> Bool
    ) async {
        let met = expectation(description: "snapshot condition")
        func check() {
            if condition(center.snapshot) {
                met.fulfill()
                return
            }
            withObservationTracking { _ = center.snapshot } onChange: {
                Task { @MainActor in check() }
            }
        }
        check()
        await fulfillment(of: [met], timeout: timeout)
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
        let center = try makeCenter(performer: LiveHomeFeedPerformer(runner: runner, pool: pool))
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
        let center = try makeCenter(performer: LiveHomeFeedPerformer(runner: runner, pool: pool))
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center, shows(ref))

        await center.act(.hide, on: ref)
        XCTAssertEqual(runner.timeouts, [30])
        XCTAssertTrue(shows(ref)(center.snapshot))
        XCTAssertEqual(center.feedErrors[ref], "watchtower exited with error: timed out after 30s")
        XCTAssertFalse(center.hiddenRefs.contains(ref))
    }

    func testSetFeedExpandedShowsEveryRow() async throws {
        let pool = try makePool()
        try await pool.write { db in
            for index in 0..<9 {
                try TestDatabase.insertInboxItem(db, messageTS: "1700000000.00010\(index)")
            }
        }
        let center = try makeCenter(performer: FakeHomeFeedPerformer())
        center.beginReading(pool: pool)
        defer { center.endReading() }
        await waitUntil(center) { $0?.feed.waiting.count == 7 }
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 2)

        center.setFeedExpanded(true)
        XCTAssertTrue(center.feedExpanded)
        XCTAssertEqual(center.snapshot?.feed.waiting.count, 9)
        XCTAssertEqual(center.snapshot?.feed.hiddenWaiting, 0)
    }

    // MARK: - LiveHomeFeedPerformer

    /// Done marks an automation output done, Hide dismisses it, both through
    /// GRDB; a second press on a closed output is quiet.
    func testAutomationOutputDoneMarksDoneAndHideDismisses() async throws {
        let pool = try makePool()
        let (done, hidden) = try await pool.write { db -> (Int64, Int64) in
            let id = try TestDatabase.insertAutomation(db)
            let run = try TestDatabase.insertAutomationRun(db, automationID: id)
            return (try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run),
                    try TestDatabase.insertAutomationOutput(db, automationID: id, runID: run))
        }
        let runner = RecordingRunner()
        let performer = LiveHomeFeedPerformer(runner: runner, pool: pool)
        try await performer.perform(.done, on: .output(done), now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .output(hidden), now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .output(done), now: Date(), calendar: .current)
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT id, read_at, done_at, dismissed_at FROM automation_outputs ORDER BY id")
        }
        XCTAssertNotNil(rows[0]["done_at"] as String?)
        XCTAssertNil(rows[0]["read_at"] as String?)
        XCTAssertNil(rows[0]["dismissed_at"] as String?)
        XCTAssertNil(rows[1]["done_at"] as String?)
        XCTAssertNil(rows[1]["read_at"] as String?)
        XCTAssertNotNil(rows[1]["dismissed_at"] as String?)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testInboxDoneRunsResolve() async throws {
        let runner = RecordingRunner()
        let performer = LiveHomeFeedPerformer(runner: runner, pool: try makePool())
        try await performer.perform(.done, on: .inbox(1), now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .inbox(1), now: Date(), calendar: .current)
        XCTAssertEqual(runner.calls, [["inbox", "resolve", "1"], ["inbox", "dismiss", "1"]])
        XCTAssertEqual(runner.timeouts, [30, 30])
    }

    /// A non-zero exit is a real failure (Go has no "not found" exit for these).
    func testInboxNonZeroExitThrows() async throws {
        let runner = RecordingRunner()
        runner.error = CLIRunnerError.nonZeroExit(code: 1, stderr: "resolving inbox item 1: database is locked")
        let performer = LiveHomeFeedPerformer(runner: runner, pool: try makePool())
        do {
            try await performer.perform(.done, on: .inbox(1), now: Date(), calendar: .current)
            XCTFail("expected the CLI error")
        } catch let error as CLIRunnerError {
            guard case .nonZeroExit(1, _) = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testNoCLIIsAnError() async throws {
        let performer = LiveHomeFeedPerformer(runner: nil, pool: try makePool())
        do {
            try await performer.perform(.done, on: .inbox(1), now: Date(), calendar: .current)
            XCTFail("expected cliUnavailable")
        } catch let error as HomeFeedActionError {
            XCTAssertEqual(error, .cliUnavailable)
        }
    }

    func testReminderHideSnoozesToTomorrowNine() async throws {
        let pool = try makePool()
        let id = try insertReminder(pool)
        let (now, calendar) = try berlin()
        try await LiveHomeFeedPerformer(runner: nil, pool: pool)
            .perform(.hide, on: .reminder(id), now: now, calendar: calendar)
        let row = try await pool.read { db in
            try Row.fetchOne(db, sql: "SELECT remind_at, status FROM reminders WHERE id = ?", arguments: [id])
        }
        // Tuesday 09:00 CEST (UTC+2).
        XCTAssertEqual(row?["remind_at"], "2026-10-20T07:00:00Z")
        XCTAssertEqual(row?["status"], "pending")
    }

    func testReminderDoneMarksDone() async throws {
        let pool = try makePool()
        let id = try insertReminder(pool)
        try await LiveHomeFeedPerformer(runner: nil, pool: pool)
            .perform(.done, on: .reminder(id), now: Date(), calendar: .current)
        let status = try await pool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM reminders WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(status, "done")
    }

    func testTargetDoneAndHide() async throws {
        let pool = try makePool()
        let (done, hidden) = try await pool.write { db in
            (Int(try TestDatabase.insertTarget(db, text: "A")), Int(try TestDatabase.insertTarget(db, text: "B")))
        }
        let performer = LiveHomeFeedPerformer(runner: nil, pool: pool)
        try await performer.perform(.done, on: .target(done), now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .target(hidden), now: Date(), calendar: .current)
        let rows = try await pool.read { db in
            try Row.fetchAll(db, sql: "SELECT status, snooze_until FROM targets ORDER BY id")
        }
        XCTAssertEqual(rows.map { $0["status"] as String }, ["done", "snoozed"])
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
            let pool = try makePool()
            let id = try await pool.write { db in Int(try TestDatabase.insertTarget(db, text: "A")) }
            try await LiveHomeFeedPerformer(runner: nil, pool: pool)
                .perform(.hide, on: .target(id), now: now, calendar: calendar)
            let stored = try await pool.read { db in
                try String.fetchOne(db, sql: "SELECT snooze_until FROM targets WHERE id = ?", arguments: [id])
            }
            XCTAssertEqual(stored, expected, zone)
        }
    }

    func testAReminderOrTargetGoneElsewhereIsQuiet() async throws {
        let performer = LiveHomeFeedPerformer(runner: nil, pool: try makePool())
        try await performer.perform(.hide, on: .reminder(999), now: Date(), calendar: .current)
        try await performer.perform(.done, on: .target(999), now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .target(999), now: Date(), calendar: .current)
    }

    func testProposalAndEventAreNoOps() async throws {
        let runner = RecordingRunner()
        let performer = LiveHomeFeedPerformer(runner: runner, pool: try makePool())
        try await performer.perform(.done, on: .proposal(1), now: Date(), calendar: .current)
        try await performer.perform(.hide, on: .event("e1"), now: Date(), calendar: .current)
        XCTAssertEqual(runner.calls, [])
    }
}
