import XCTest
import GRDB
@testable import WatchtowerDesktop

final class ObserverQueriesTests: XCTestCase {

    /// Builds an in-memory DB with the observers/observer_events tables.
    private func makeDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE observers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    entity_type TEXT NOT NULL DEFAULT 'target',
                    entity_id INTEGER NOT NULL,
                    name TEXT NOT NULL DEFAULT '',
                    instruction TEXT NOT NULL DEFAULT '',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    last_run_at TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL DEFAULT '',
                    updated_at TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE observer_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    observer_id INTEGER NOT NULL,
                    entity_type TEXT NOT NULL DEFAULT 'target',
                    entity_id INTEGER NOT NULL,
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

    func testCreateFetchUpdateDelete() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            let id = try ObserverQueries.create(db, entityId: 5, name: "W", instruction: "watch")
            XCTAssertGreaterThan(id, 0)

            var obs = try ObserverQueries.fetchForEntity(db, entityId: 5)
            XCTAssertEqual(obs.count, 1)
            XCTAssertEqual(obs[0].name, "W")
            XCTAssertTrue(obs[0].enabled)

            try ObserverQueries.update(db, id: Int(id), name: "W2", instruction: "watch2")
            try ObserverQueries.setEnabled(db, id: Int(id), enabled: false)
            obs = try ObserverQueries.fetchForEntity(db, entityId: 5)
            XCTAssertEqual(obs[0].name, "W2")
            XCTAssertFalse(obs[0].enabled)

            try ObserverQueries.delete(db, id: Int(id))
            XCTAssertEqual(try ObserverQueries.fetchForEntity(db, entityId: 5).count, 0)
        }
    }

    func testEventsDecodeAndReadAndAction() throws {
        let dbQueue = try makeDB()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO observer_events
                  (observer_id, entity_id, summary, source_type, source_refs, decision, proposed_action, action_status)
                VALUES (1, 9, 'decided X', 'digest', '["https://x"]',
                        '{"text":"go plan B","by":"@ann","importance":"high"}',
                        '{"type":"update_status","reason":"decided","status":"in_progress"}', 'pending')
                """)
            let events = try ObserverQueries.fetchEvents(db, entityId: 9)
            XCTAssertEqual(events.count, 1)
            let e = events[0]
            XCTAssertTrue(e.isUnread)
            XCTAssertEqual(e.decodedRefs, ["https://x"])
            XCTAssertEqual(e.decodedDecisionText, "go plan B")
            XCTAssertEqual(e.decodedAction?.type, .updateStatus)
            XCTAssertEqual(e.decodedAction?.status, "in_progress")

            XCTAssertEqual(try ObserverQueries.unreadCount(db, entityId: 9), 1)
            try ObserverQueries.markRead(db, id: e.id)
            try ObserverQueries.setActionStatus(db, id: e.id, status: "applied")
            let after = try ObserverQueries.fetchEvents(db, entityId: 9)
            XCTAssertFalse(after[0].isUnread)
            XCTAssertEqual(after[0].actionStatus, "applied")
            XCTAssertEqual(try ObserverQueries.unreadCount(db, entityId: 9), 0)
        }
    }
}
