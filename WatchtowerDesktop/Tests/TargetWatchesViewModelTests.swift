import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class TargetWatchesViewModelTests: XCTestCase {

    // Mirrors the track_events DDL the CustomTrackTimeline tests use, so the
    // test DB has the table the app schema creates at runtime.
    static let trackEventsSQL = """
        ALTER TABLE tracks ADD COLUMN origin TEXT NOT NULL DEFAULT 'auto';
        ALTER TABLE tracks ADD COLUMN instruction TEXT NOT NULL DEFAULT '';
        ALTER TABLE tracks ADD COLUMN enabled INTEGER NOT NULL DEFAULT 1;
        ALTER TABLE tracks ADD COLUMN last_run_at TEXT NOT NULL DEFAULT '';
        ALTER TABLE tracks ADD COLUMN linked_target_id INTEGER;
        CREATE TABLE IF NOT EXISTS track_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            summary TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '',
            source_type TEXT NOT NULL DEFAULT '', source_id TEXT NOT NULL DEFAULT '',
            source_refs TEXT NOT NULL DEFAULT '[]', decision TEXT NOT NULL DEFAULT '',
            proposed_action TEXT NOT NULL DEFAULT '',
            action_status TEXT NOT NULL DEFAULT 'none',
            read_at TEXT, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
        );
        """

    private func makeWatch(_ db: Database, targetID: Int?, text: String) throws -> Int {
        try db.execute(sql: """
            INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                origin, instruction, enabled, linked_target_id)
            VALUES ('U1', ?, '', 'task', 'watching', 'medium', 'custom', 'watch', 1, ?)
            """, arguments: [text, targetID])
        return Int(db.lastInsertedRowID)
    }

    func testFetchForTargetScopesToTargetsWatches() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try db.execute(sql: Self.trackEventsSQL) }

        let t1 = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal one", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let t2 = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal two", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        try manager.dbPool.write { db in
            let w1 = try makeWatch(db, targetID: t1, text: "watch A")
            let w2 = try makeWatch(db, targetID: t2, text: "watch B")
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'a1', '2026-06-10T00:00:00Z')", arguments: [w1])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'a2', '2026-06-11T00:00:00Z')", arguments: [w1])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'b1', '2026-06-12T00:00:00Z')", arguments: [w2])
        }
        let events = try manager.dbPool.read { db in
            try TrackEventQueries.fetchForTarget(db, targetID: t1)
        }
        XCTAssertEqual(events.map(\.summary), ["a2", "a1"], "only t1's watch events, newest-first")
    }
}
