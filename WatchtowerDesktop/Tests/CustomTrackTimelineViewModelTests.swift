import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class CustomTrackTimelineViewModelTests: XCTestCase {

    /// Builds a manager + a custom track. When `linkToTarget` is true the track's
    /// linked_target_id points at a freshly created target (so applyAction has a
    /// real row to mutate); otherwise the track is standalone (linked id NULL).
    private func makeHarness(
        linkToTarget: Bool = true,
        scanRunner: CLIRunnerProtocol = FakeCLIRunner(stdout: Data("[]".utf8)),
        actionRunner: CLIRunnerProtocol = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
    ) throws -> (manager: DatabaseManager, path: String, track: Track, timeline: CustomTrackTimelineViewModel) {
        let (manager, path) = try TestDatabase.createDatabaseManager()

        var targetID: Int?
        if linkToTarget {
            targetID = try manager.dbPool.write { db in
                try TargetQueries.create(db, text: "watched", periodStart: "2026-06-01", periodEnd: "2026-06-30")
            }
        }
        let trackID = try manager.dbPool.write { db -> Int in
            try db.execute(sql: """
                INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                    origin, instruction, enabled, linked_target_id)
                VALUES ('U1', 'Watch the refund', 'refund ownership', 'task', 'watching', 'medium',
                    'custom', 'watch the refund decision', 1, ?)
                """, arguments: [targetID])
            return Int(db.lastInsertedRowID)
        }
        let track = try XCTUnwrap(manager.dbPool.read { db in try TrackQueries.fetchByID(db, id: trackID) })
        let timeline = CustomTrackTimelineViewModel(
            track: track,
            dbManager: manager,
            scanService: TrackScanService(runner: scanRunner),
            actionRunner: actionRunner,
            scanCenter: TrackScanCenter()
        )
        return (manager, path, track, timeline)
    }

    private func insertPendingEvent(_ manager: DatabaseManager, trackID: Int, summary: String, action: String) throws {
        try manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, proposed_action, action_status)
                VALUES (?, ?, ?, 'pending')
                """, arguments: [trackID, summary, action])
        }
    }

    private func firstEvent(_ manager: DatabaseManager, _ track: Track) async throws -> TrackEvent {
        let events = try await manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }
        return events[0]
    }

    /// The press goes through the registry: one `actions propose --approve`
    /// for the event, and the Desktop writes nothing itself. The fake CLI
    /// marks the event applied (Go's side effect); the timeline shows it
    /// right after the call, without any observation running.
    func testApplyRefreshesTheEventAfterThePress() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let (manager, path, track, timeline) = try makeHarness(actionRunner: runner)
        defer { TestDatabase.cleanup(path: path) }
        try insertPendingEvent(manager, trackID: track.id, summary: "first",
                               action: #"{"type":"add_sub_item","reason":"r1","text":"first item"}"#)
        let event = try await firstEvent(manager, track)
        let pool = manager.dbPool
        runner.onRun = { _ in
            try? await pool.write { db in try db.execute(sql: "UPDATE track_events SET action_status = 'applied'") }
        }

        await timeline.applyAction(for: event)

        XCTAssertNil(timeline.errorMessage)
        XCTAssertEqual(runner.invocations, [TrackActionPress.arguments(eventID: event.id)])
        XCTAssertEqual(timeline.events.map(\.actionStatus), ["applied"])
    }

    /// A second press while the first waits must not reach the CLI.
    func testPressWhileWaitingRunsOnce() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        runner.onRun = { _ in try? await Task.sleep(for: .milliseconds(200)) }
        let (manager, path, track, timeline) = try makeHarness(actionRunner: runner)
        defer { TestDatabase.cleanup(path: path) }
        try insertPendingEvent(manager, trackID: track.id, summary: "first",
                               action: #"{"type":"add_sub_item","reason":"r1","text":"first item"}"#)
        let event = try await firstEvent(manager, track)

        async let first: Void = timeline.applyAction(for: event)
        async let second: Void = timeline.applyAction(for: event)
        _ = await (first, second)

        XCTAssertEqual(runner.invocations.count, 1)
    }

    /// The CLI's refusal (a non-zero exit) is shown as the error and the
    /// event stays as the CLI left it.
    func testRefusedPressShowsTheCLIText() async throws {
        let runner = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "This change was already applied.\n"))
        let (manager, path, track, timeline) = try makeHarness(actionRunner: runner)
        defer { TestDatabase.cleanup(path: path) }
        try insertPendingEvent(manager, trackID: track.id, summary: "stale",
                               action: #"{"type":"add_sub_item","reason":"r","text":"x"}"#)

        await timeline.applyAction(for: try await firstEvent(manager, track))

        XCTAssertEqual(timeline.errorMessage, "This change was already applied.")
        let status = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events")
        }
        XCTAssertEqual(status, "pending")
    }

    /// A standalone custom track (no linked target) must not apply proposed
    /// actions: the scan prompt already suppresses them, and there is no target
    /// to mutate. Apply is a no-op that runs nothing and leaves the event pending.
    func testApplyOnAStandaloneTrackRunsNothing() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"ok":true,"applied_ok":true,"error":""}"#.utf8))
        let (manager, path, track, timeline) = try makeHarness(linkToTarget: false, actionRunner: runner)
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertNil(track.linkedTargetID)

        try insertPendingEvent(manager, trackID: track.id, summary: "orphan",
                               action: #"{"type":"add_sub_item","reason":"r","text":"x"}"#)
        let events = try await manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }

        await timeline.applyAction(for: events[0])

        XCTAssertNil(timeline.errorMessage)
        let status = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events")
        }
        XCTAssertEqual(status, "pending", "standalone tracks must not apply/consume the action")
        XCTAssertTrue(runner.invocations.isEmpty)
        XCTAssertFalse(timeline.canApplyActions)
    }

    /// scanSinceLast force-runs the scan via the CLI; a runner failure must surface
    /// through errorMessage (not be swallowed as "no new events").
    func testRefreshNowSurfacesScanFailure() async throws {
        struct Boom: Error {}
        let (_, path, _, timeline) = try makeHarness(scanRunner: FakeCLIRunner(error: Boom()))
        defer { TestDatabase.cleanup(path: path) }

        await timeline.scanSinceLast()
        XCTAssertNotNil(timeline.errorMessage)
        XCTAssertFalse(timeline.isRefreshing)
    }

    /// A successful scan invocation clears the in-progress flags and reports no
    /// error (empty "[]" output decodes cleanly).
    func testRefreshNowSuccessLeavesNoError() async throws {
        let (_, path, _, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }

        await timeline.scanSinceLast()
        XCTAssertNil(timeline.errorMessage)
        XCTAssertFalse(timeline.isRefreshing)
    }

    /// The scan runs via a CLI subprocess writing on its own SQLite connection,
    /// so a same-process ValueObservation (as `start()` sets up) never sees
    /// those rows. This test never calls `start()`, isolating the fix: the
    /// timeline must refresh from `scanSinceLast` alone.
    func testScanSinceLastRefreshesTimelineWithoutAnyObservationRunning() async throws {
        let (manager, path, track, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertTrue(timeline.events.isEmpty)

        // Simulate the CLI subprocess having already written a new row (on its
        // own connection) by the time scanSinceLast's await returns.
        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, created_at)
                VALUES (?, 'new update', '2026-07-01T00:00:00Z')
                """, arguments: [track.id])
        }

        await timeline.scanSinceLast()

        XCTAssertEqual(timeline.events.map(\.summary), ["new update"], "the timeline must reflect the CLI's write without an active observation")
    }

    /// Same as above but through the `scanHistory` path (used by the "Scan
    /// history" backfill action), which has its own refetch call site.
    func testScanHistoryRefreshesTimelineWithoutAnyObservationRunning() async throws {
        let (manager, path, track, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertTrue(timeline.events.isEmpty)

        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, created_at)
                VALUES (?, 'backfilled update', '2026-01-01T00:00:00Z')
                """, arguments: [track.id])
        }

        await timeline.scanHistory(since: nil, label: "all history")

        XCTAssertEqual(
            timeline.events.map(\.summary),
            ["backfilled update"],
            "the timeline must reflect the CLI's write without an active observation"
        )
    }

    /// dismissAction records the event's action_status without touching any
    /// target.
    func testDismissActionSetsDismissed() async throws {
        let (manager, path, track, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }

        try insertPendingEvent(manager, trackID: track.id, summary: "skip",
                               action: #"{"type":"update_status","reason":"r","status":"done"}"#)
        let events = try await manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }

        await timeline.dismissAction(for: events[0])

        XCTAssertNil(timeline.errorMessage)
        let status = try await manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events")
        }
        XCTAssertEqual(status, "dismissed")
    }

    func testLastScannedTextEmptyMeansNotScannedYet() {
        XCTAssertEqual(CustomTrackTimelineViewModel.lastScannedText(lastRunAt: ""), "Not scanned yet")
    }

    func testLastScannedTextRendersRelativeAgeForAValidTimestamp() {
        let iso = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        let text = CustomTrackTimelineViewModel.lastScannedText(lastRunAt: iso)
        XCTAssertTrue(text.hasPrefix("Last scanned "), text)
        XCTAssertFalse(text.contains(iso), "relative text, not the raw timestamp")
    }
}
