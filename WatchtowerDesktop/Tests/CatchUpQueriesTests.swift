import XCTest
import GRDB
@testable import WatchtowerDesktop

final class CatchUpQueriesTests: XCTestCase {

    // MARK: - Helpers

    private func insertSession(
        _ db: Database,
        status: String = "active",
        oldestUnread: String = "2026-06-01T00:00:00Z",
        totalThemes: Int = 0,
        reviewedCount: Int = 0
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO catchup_sessions (created_at, status, oldest_unread, total_themes, reviewed_count)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: ["2026-06-20T00:00:00Z", status, oldestUnread, totalThemes, reviewedCount]
        )
        return db.lastInsertedRowID
    }

    private func insertTheme(
        _ db: Database,
        sessionID: Int64,
        orderIdx: Int = 0,
        title: String = "Theme",
        narrative: String = "Narrative",
        priority: String = "medium",
        needsYou: Bool = false,
        suggestedAction: String = "",
        refs: String = "[]",
        genState: String = "ready",
        reviewState: String = "pending"
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO catchup_themes
                    (session_id, order_idx, title, narrative, priority, needs_you,
                     suggested_action, refs, gen_state, review_state, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                sessionID, orderIdx, title, narrative, priority, needsYou ? 1 : 0,
                suggestedAction, refs, genState, reviewState,
                "2026-06-20T00:00:00Z", "2026-06-20T00:00:00Z"
            ]
        )
        return db.lastInsertedRowID
    }

    // MARK: - Fetch

    func testFetchActiveSession() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            _ = try insertSession(db, status: "done")
            _ = try insertSession(db, status: "active", totalThemes: 4, reviewedCount: 1)
        }

        let session = try dbQueue.read { db in
            try CatchUpQueries.fetchActiveSession(db)
        }
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.status, "active")
        XCTAssertEqual(session?.totalThemes, 4)
        XCTAssertEqual(session?.reviewedCount, 1)
    }

    func testFetchActiveSessionNilWhenNoneActive() throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            _ = try insertSession(db, status: "done")
        }
        let session = try dbQueue.read { db in
            try CatchUpQueries.fetchActiveSession(db)
        }
        XCTAssertNil(session)
    }

    func testFetchThemesParsesRefs() throws {
        let dbQueue = try TestDatabase.create()
        let sessionID = try dbQueue.write { db -> Int64 in
            let sid = try insertSession(db)
            _ = try insertTheme(
                db, sessionID: sid, orderIdx: 1, title: "Second"
            )
            _ = try insertTheme(
                db, sessionID: sid, orderIdx: 0, title: "First", needsYou: true,
                refs: ##"[{"area":"inbox","id":7,"label":"Ping from Alice"},{"area":"digest","id":3,"label":"#general"}]"##
            )
            return sid
        }

        let themes = try dbQueue.read { db in
            try CatchUpQueries.fetchThemes(db, sessionID: Int(sessionID))
        }
        XCTAssertEqual(themes.count, 2)
        // Ordered by order_idx.
        XCTAssertEqual(themes[0].title, "First")
        XCTAssertEqual(themes[1].title, "Second")
        XCTAssertTrue(themes[0].needsYou)

        let refs = themes[0].decodedRefs
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].area, "inbox")
        XCTAssertEqual(refs[0].id, 7)
        XCTAssertEqual(refs[0].label, "Ping from Alice")
        XCTAssertEqual(refs[1].area, "digest")
        XCTAssertEqual(refs[1].id, 3)
    }

    // MARK: - Acknowledge cascade

    func testAcknowledgeCascadesMarkReadAndFlipsReviewState() throws {
        let dbQueue = try TestDatabase.create()
        let ctx = try dbQueue.write { db -> (sid: Int64, themeID: Int64) in
            try TestDatabase.insertWorkspace(db)
            try TestDatabase.insertChannel(db)
            try TestDatabase.insertUser(db)
            // One referenced inbox item (id 1) and one unreferenced (id 2).
            try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000100")
            try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000200")

            let sid = try insertSession(db, totalThemes: 1, reviewedCount: 0)
            let themeID = try insertTheme(
                db, sessionID: sid,
                refs: #"[{"area":"inbox","id":1,"label":"Ping"}]"#
            )
            return (sid, themeID)
        }

        let theme = try dbQueue.read { db in
            try CatchUpQueries.fetchThemes(db, sessionID: Int(ctx.sid)).first { $0.id == Int(ctx.themeID) }
        }
        let unwrapped = try XCTUnwrap(theme)

        try dbQueue.write { db in
            try CatchUpQueries.acknowledge(db, theme: unwrapped)
        }

        try dbQueue.read { db in
            // Referenced inbox item is read; the other stays unread.
            let item1Read: String? = try String.fetchOne(
                db, sql: "SELECT read_at FROM inbox_items WHERE id = 1"
            )
            XCTAssertNotNil(item1Read)
            XCTAssertFalse((item1Read ?? "").isEmpty)
            let item2Read: String? = try String.fetchOne(
                db, sql: "SELECT read_at FROM inbox_items WHERE id = 2"
            )
            XCTAssertTrue((item2Read ?? "").isEmpty)

            // Theme review_state flipped to reviewed.
            let reviewState = try String.fetchOne(
                db, sql: "SELECT review_state FROM catchup_themes WHERE id = ?", arguments: [ctx.themeID]
            )
            XCTAssertEqual(reviewState, "reviewed")

            // Session reviewed_count incremented.
            let reviewed = try Int.fetchOne(
                db, sql: "SELECT reviewed_count FROM catchup_sessions WHERE id = ?", arguments: [ctx.sid]
            )
            XCTAssertEqual(reviewed, 1)
        }
    }

    func testAcknowledgeReviewedCountIsIdempotent() throws {
        let dbQueue = try TestDatabase.create()
        let ctx = try dbQueue.write { db -> (sid: Int64, themeID: Int64) in
            let sid = try insertSession(db, totalThemes: 1, reviewedCount: 0)
            let themeID = try insertTheme(db, sessionID: sid, refs: "[]")
            return (sid, themeID)
        }

        // First ack: pending → reviewed, count becomes 1.
        let pending = try dbQueue.read { db in
            try CatchUpQueries.fetchTheme(db, id: Int(ctx.themeID))
        }
        try dbQueue.write { db in
            try CatchUpQueries.acknowledge(db, theme: try XCTUnwrap(pending))
        }

        // Re-ack with the now-reviewed row: count must not advance past 1.
        let reviewed = try dbQueue.read { db in
            try CatchUpQueries.fetchTheme(db, id: Int(ctx.themeID))
        }
        try dbQueue.write { db in
            try CatchUpQueries.acknowledge(db, theme: try XCTUnwrap(reviewed))
        }

        let count = try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT reviewed_count FROM catchup_sessions WHERE id = ?", arguments: [ctx.sid]
            )
        }
        XCTAssertEqual(count, 1, "re-acking a reviewed theme must not double-count")
    }

    func testSetReviewAndSetTask() throws {
        let dbQueue = try TestDatabase.create()
        let themeID = try dbQueue.write { db -> Int64 in
            let sid = try insertSession(db)
            return try insertTheme(db, sessionID: sid)
        }

        try dbQueue.write { db in
            try CatchUpQueries.setReview(db, id: Int(themeID), state: "snoozed", snoozeUntil: "2026-07-01T00:00:00Z")
            try CatchUpQueries.setTask(db, id: Int(themeID), taskID: 99)
        }

        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT review_state, snooze_until, task_id FROM catchup_themes WHERE id = ?",
                arguments: [themeID]
            )
            XCTAssertEqual(row?["review_state"], "snoozed")
            XCTAssertEqual(row?["snooze_until"], "2026-07-01T00:00:00Z")
            XCTAssertEqual(row?["task_id"], 99)
        }
    }
}
