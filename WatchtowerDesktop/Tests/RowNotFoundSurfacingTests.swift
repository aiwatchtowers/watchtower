import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The visible half of the zero-row checks: an owner edit of a row deleted in
/// another process names it, and the vanished row leaves the screen instead
/// of failing again on every retry. The query-level half is
/// `Tests/Core/RowNotFoundWritersTests`.
@MainActor
final class RowNotFoundSurfacingTests: XCTestCase {

    func testRecordingNotes_OnADeletedRecording_ThrowNotFound() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int64 in
            try TestDatabase.insertMeetingTranscript(db)
            let id = db.lastInsertedRowID
            try db.execute(sql: "DELETE FROM meeting_transcripts WHERE id = ?", arguments: [id])
            return id
        }

        XCTAssertThrowsError(try queue.write { try MeetingTranscriptQueries.saveNotes($0, id: id, markdown: "# notes") }) {
            XCTAssertEqual($0 as? RowNotFoundError, RowNotFoundError(kind: "recording", id: id))
        }
    }

    func testTrackEdit_OfATrackDeletedElsewhere_NamesIt_AndDropsTheRow() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let id = try manager.dbPool.write { db -> Int64 in
            try TestDatabase.insertWorkspace(db)
            return try TestDatabase.insertTrack(db, text: "gone soon")
        }
        let vm = TracksViewModel(dbManager: manager)
        vm.load()
        let stale = try XCTUnwrap((vm.updatedTracks + vm.allTracks).first { Int64($0.id) == id })
        // No `load()` after the delete: the VM never sees another process's write.
        try manager.dbPool.write { db in try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [id]) }

        vm.updatePriority(stale, to: "high")

        XCTAssertEqual(
            vm.errorMessage,
            "Failed to update priority: \(RowNotFoundError(kind: "track", id: id).localizedDescription)"
        )
        XCTAssertFalse((vm.updatedTracks + vm.allTracks).contains { Int64($0.id) == id })
    }

    /// The event's watch was deleted elsewhere (the delete cascades to its
    /// events): Apply must fail BEFORE touching the target, or the action
    /// would land and still be reported as failed — and re-land on a retry.
    func testWatchApply_OfAnEventDeletedElsewhere_LeavesTheTargetAlone() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        let targetID = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "goal", periodStart: "2026-09-01", periodEnd: "2026-09-30")
        }
        let eventID = try manager.dbPool.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                    origin, instruction, enabled, linked_target_id)
                VALUES ('U1', 'watch', '', 'task', 'watching', 'medium', 'custom', 'watch', 1, ?)
                """, arguments: [targetID])
            let watchID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, proposed_action)
                VALUES (?, 'shipped', '{"type":"update_status","reason":"r","status":"done"}')
                """, arguments: [watchID])
            return db.lastInsertedRowID
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID) })
        let event = try XCTUnwrap(manager.dbPool.read { db in
            try TrackEventQueries.fetchForTarget(db, targetID: targetID).first
        })
        XCTAssertNotNil(event.decodedAction)
        let vm = TargetWatchesViewModel(
            target: target,
            dbManager: manager,
            scanService: TrackScanService(runner: FakeCLIRunner(stdout: Data("[]".utf8))),
            targetsViewModel: TargetsViewModel(dbManager: manager),
            scanCenter: TrackScanCenter()
        )
        vm.events = [event]
        try manager.dbPool.write { db in try db.execute(sql: "DELETE FROM tracks") }

        vm.applyAction(for: event)

        XCTAssertEqual(
            vm.errorMessage,
            "Failed to apply: \(RowNotFoundError(kind: "track event", id: eventID).localizedDescription)"
        )
        XCTAssertTrue(vm.events.isEmpty, "the vanished event leaves the feed")
        let status = try manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID)?.status }
        XCTAssertEqual(status, "todo", "the target was not touched")
    }
}
