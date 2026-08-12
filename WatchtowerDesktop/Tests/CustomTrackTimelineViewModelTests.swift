import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class CustomTrackTimelineViewModelTests: XCTestCase {

    /// Mirrors the Go-side track_events DDL; the shared TestDatabase.schema
    /// predates custom tracks, so the harness patches the tracks table with the
    /// custom-only columns (origin/instruction/enabled/last_run_at) and adds
    /// the track_events table. linked_target_id is now part of the shared
    /// schema itself (Secretary Memory Slice C) — no longer patched here.
    private static let trackEventsSQL = """
        ALTER TABLE tracks ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto';
        ALTER TABLE tracks ADD COLUMN instruction TEXT NOT NULL DEFAULT '';
        ALTER TABLE tracks ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE tracks ADD COLUMN last_run_at TEXT NOT NULL DEFAULT '';
        CREATE TABLE track_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            detail TEXT NOT NULL DEFAULT '',
            source_type TEXT NOT NULL DEFAULT '',
            source_id TEXT NOT NULL DEFAULT '',
            source_refs TEXT NOT NULL DEFAULT '[]',
            decision TEXT NOT NULL DEFAULT '',
            proposed_action TEXT NOT NULL DEFAULT '',
            action_status TEXT NOT NULL DEFAULT 'none',
            read_at TEXT,
            created_at TEXT NOT NULL DEFAULT ''
        );
        """

    /// Builds a manager + a custom track. When `linkToTarget` is true the track's
    /// linked_target_id points at a freshly created target (so applyAction has a
    /// real row to mutate); otherwise the track is standalone (linked id NULL).
    private func makeHarness(
        linkToTarget: Bool = true,
        scanRunner: CLIRunnerProtocol = FakeCLIRunner(stdout: Data("[]".utf8))
    ) throws -> (manager: DatabaseManager, path: String, track: Track, timeline: CustomTrackTimelineViewModel) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        try manager.dbPool.write { db in try db.execute(sql: Self.trackEventsSQL) }

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
            targetsViewModel: TargetsViewModel(dbManager: manager),
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

    /// Two sequentially approved add_sub_item actions must BOTH persist against
    /// the LINKED target: the executor's sub-item path is a whole-JSON
    /// read-modify-write, so applying against a stale snapshot would clobber the
    /// first write. Ported from ObserverTimelineViewModelTests.
    func testApplyTwoAddSubItemActions_BothPersistToLinkedTarget() throws {
        let (manager, path, track, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }

        try insertPendingEvent(manager, trackID: track.id, summary: "first",
                               action: #"{"type":"add_sub_item","reason":"r1","text":"first item"}"#)
        try insertPendingEvent(manager, trackID: track.id, summary: "second",
                               action: #"{"type":"add_sub_item","reason":"r2","text":"second item"}"#)

        let events = try manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }
        XCTAssertEqual(events.count, 2)

        // fetchEvents is DESC — apply oldest first to mirror timeline order.
        timeline.applyAction(for: events[1])
        timeline.applyAction(for: events[0])

        XCTAssertNil(timeline.errorMessage)
        let linkedID = try XCTUnwrap(track.linkedTargetID)
        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: linkedID) })
        XCTAssertEqual(after.decodedSubItems.map(\.text).sorted(), ["first item", "second item"])
        let statuses = try manager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT action_status FROM track_events ORDER BY id")
        }
        XCTAssertEqual(statuses, ["applied", "applied"])
    }

    /// Applying an action after the linked target row was deleted must surface an
    /// error and leave the event pending — silently marking it applied would lose
    /// the mutation with no feedback.
    func testApplyActionAgainstDeletedTarget_SetsErrorAndLeavesEventPending() throws {
        let (manager, path, track, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }

        try insertPendingEvent(manager, trackID: track.id, summary: "stale",
                               action: #"{"type":"add_sub_item","reason":"r","text":"x"}"#)
        let events = try manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }
        let linkedID = try XCTUnwrap(track.linkedTargetID)
        try manager.dbPool.write { db in
            try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [linkedID])
        }

        timeline.applyAction(for: events[0])

        XCTAssertNotNil(timeline.errorMessage)
        let status = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events")
        }
        XCTAssertEqual(status, "pending", "the event must stay pending when the linked target is gone")
    }

    /// A standalone custom track (no linked target) must not apply proposed
    /// actions: the scan prompt already suppresses them, and there is no target
    /// to mutate. Apply is a no-op that leaves the event pending, without error.
    func testApplyActionStandaloneTrack_IsNoOp() throws {
        let (manager, path, track, timeline) = try makeHarness(linkToTarget: false)
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertNil(track.linkedTargetID)

        try insertPendingEvent(manager, trackID: track.id, summary: "orphan",
                               action: #"{"type":"add_sub_item","reason":"r","text":"x"}"#)
        let events = try manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }

        timeline.applyAction(for: events[0])

        XCTAssertNil(timeline.errorMessage)
        let status = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events")
        }
        XCTAssertEqual(status, "pending", "standalone tracks must not apply/consume the action")
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
    func testDismissActionSetsDismissed() throws {
        let (manager, path, track, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }

        try insertPendingEvent(manager, trackID: track.id, summary: "skip",
                               action: #"{"type":"update_status","reason":"r","status":"done"}"#)
        let events = try manager.dbPool.read { db in try TrackEventQueries.fetchEvents(db, trackId: track.id) }

        timeline.dismissAction(for: events[0])

        XCTAssertNil(timeline.errorMessage)
        let status = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events")
        }
        XCTAssertEqual(status, "dismissed")
    }
}
