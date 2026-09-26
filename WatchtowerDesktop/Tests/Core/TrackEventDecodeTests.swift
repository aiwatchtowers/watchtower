import XCTest
import GRDB
@testable import WatchtowerCore

final class TrackEventDecodeTests: XCTestCase {

    /// Builds an in-memory DB with a track_events table matching the Go schema.
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
                """)
        }
        return dbQueue
    }

    // MARK: - FetchableRecord column mapping

    func testFetchDecodesColumns() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track_events
                    (track_id, summary, detail, source_type, source_id, source_refs,
                     decision, proposed_action, action_status, read_at, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    7, "refund approved", "extra", "digest", "42",
                    #"["http://x","http://y"]"#,
                    #"{"text":"Approved by finance","by":"@ann","importance":"high"}"#,
                    #"{"type":"update_status","reason":"resolved","status":"done"}"#,
                    "pending", nil, "2026-07-04T00:00:00Z"
                ])
        }
        let event = try XCTUnwrap(dbQueue.read {
            try TrackEvent.fetchOne($0, sql: "SELECT * FROM track_events LIMIT 1")
        })

        XCTAssertEqual(event.trackId, 7)
        XCTAssertEqual(event.summary, "refund approved")
        XCTAssertEqual(event.sourceType, "digest")
        XCTAssertEqual(event.sourceId, "42")
        XCTAssertEqual(event.actionStatus, "pending")
        XCTAssertTrue(event.isUnread)

        XCTAssertEqual(event.decodedRefs, ["http://x", "http://y"])
        XCTAssertEqual(event.decodedDecisionText, "Approved by finance")

        let action = try XCTUnwrap(event.decodedAction)
        XCTAssertEqual(action.type, .updateStatus)
        XCTAssertEqual(action.status, "done")
    }

    func testReadEventIsNotUnread() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, read_at, created_at)
                VALUES (?, ?, ?, ?)
                """, arguments: [1, "seen", "2026-07-04T01:00:00Z", "2026-07-04T00:00:00Z"])
        }
        let event = try XCTUnwrap(dbQueue.read {
            try TrackEvent.fetchOne($0, sql: "SELECT * FROM track_events LIMIT 1")
        })
        XCTAssertFalse(event.isUnread)
    }

    // MARK: - Empty / absent optionals

    func testEmptyDecodersReturnNil() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, source_refs, decision, proposed_action, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [2, "bare", "[]", "", "", "2026-07-04T00:00:00Z"])
        }
        let event = try XCTUnwrap(dbQueue.read {
            try TrackEvent.fetchOne($0, sql: "SELECT * FROM track_events LIMIT 1")
        })
        XCTAssertTrue(event.decodedRefs.isEmpty)
        XCTAssertNil(event.decodedDecisionText)
        XCTAssertNil(event.decodedAction)
        XCTAssertTrue(event.isUnread)
    }
}
