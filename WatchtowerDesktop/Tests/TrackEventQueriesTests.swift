import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TrackEventQueriesTests: XCTestCase {

    /// Builds an in-memory DB with the track_events + inbox_items tables. The
    /// track_id FK is left unenforced (no REFERENCES clause) so events can be
    /// inserted without seeding a parent tracks row.
    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
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
                CREATE TABLE inbox_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    permalink TEXT NOT NULL DEFAULT ''
                );
                """)
        }
        return dbQueue
    }

    func testEventsDecodeAndReadAndAction() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track_events
                  (track_id, summary, source_type, source_refs, decision, proposed_action, action_status)
                VALUES (9, 'decided X', 'digest', '["https://x"]',
                        '{"text":"go plan B","by":"@ann","importance":"high"}',
                        '{"type":"update_status","reason":"decided","status":"in_progress"}', 'pending')
                """)
            let events = try TrackEventQueries.fetchEvents(db, trackId: 9)
            XCTAssertEqual(events.count, 1)
            let e = events[0]
            XCTAssertTrue(e.isUnread)
            XCTAssertEqual(e.decodedRefs, ["https://x"])
            XCTAssertEqual(e.decodedDecisionText, "go plan B")
            XCTAssertEqual(e.decodedAction?.type, .updateStatus)
            XCTAssertEqual(e.decodedAction?.status, "in_progress")

            XCTAssertEqual(try TrackEventQueries.unreadCount(db, trackId: 9), 1)
            try TrackEventQueries.markRead(db, id: e.id)
            try TrackEventQueries.setActionStatus(db, id: e.id, status: "applied")
            let after = try TrackEventQueries.fetchEvents(db, trackId: 9)
            XCTAssertFalse(after[0].isUnread)
            XCTAssertEqual(after[0].actionStatus, "applied")
            XCTAssertEqual(try TrackEventQueries.unreadCount(db, trackId: 9), 0)
        }
    }

    func testSourcePermalinkResolvesInbox() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO inbox_items (id, permalink) VALUES (3, 'https://slack/x')")
            XCTAssertEqual(try TrackEventQueries.sourcePermalink(db, sourceType: "inbox", sourceId: "3"),
                           "https://slack/x")
            XCTAssertNil(try TrackEventQueries.sourcePermalink(db, sourceType: "digest", sourceId: "1"))
        }
    }
}
