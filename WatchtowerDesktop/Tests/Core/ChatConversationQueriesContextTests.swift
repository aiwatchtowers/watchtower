import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The two multi-conversation readers behind the target assistant tabs.
/// `chat_conversations` is Swift-owned (created by `ensureTable`), so these
/// tests build it themselves rather than expecting it in the shared schema.
final class ChatConversationQueriesContextTests: XCTestCase {

    private func makeDB() throws -> DatabaseQueue {
        let db = try TestDatabase.create()
        try db.write { db in
            try ChatConversationQueries.ensureTable(db)
            // `chat_messages` is created by the Desktop module (ChatMessageQueries,
            // outside WatchtowerCore), so its shape is spelled out here — the
            // turn-activity reader joins the two.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS chat_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    text TEXT NOT NULL,
                    created_at REAL NOT NULL
                )
            """)
        }
        return db
    }

    private func insertMessage(
        _ db: Database, conversationID: Int64, role: String = "user", createdAt: Double
    ) throws {
        try db.execute(
            sql: "INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, ?)",
            arguments: [conversationID, role, "hi", createdAt]
        )
    }

    @discardableResult
    private func insert(
        _ db: Database,
        title: String,
        contextType: String? = "target",
        contextID: String? = "7",
        createdAt: Double,
        updatedAt: Double
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [title, contextType, contextID, createdAt, updatedAt]
        )
        return db.lastInsertedRowID
    }

    // MARK: - fetchAllByContext

    func testFetchAllByContextOrdersByCreatedAtAscending() throws {
        let db = try makeDB()
        try db.write { db in
            // Inserted newest-first and touched out of order: neither insertion
            // order nor updated_at may decide the tab order.
            try insert(db, title: "second", createdAt: 200, updatedAt: 900)
            try insert(db, title: "first", createdAt: 100, updatedAt: 100)
            try insert(db, title: "third", createdAt: 300, updatedAt: 500)
        }

        let rows = try db.read { try ChatConversationQueries.fetchAllByContext($0, type: "target", id: "7") }
        XCTAssertEqual(rows.map(\.title), ["first", "second", "third"])
    }

    func testFetchAllByContextIgnoresOtherContexts() throws {
        let db = try makeDB()
        try db.write { db in
            try insert(db, title: "mine", createdAt: 100, updatedAt: 100)
            try insert(db, title: "other target", contextID: "8", createdAt: 110, updatedAt: 110)
            try insert(db, title: "situation", contextType: "situation", createdAt: 120, updatedAt: 120)
            try insert(db, title: "standalone", contextType: nil, contextID: nil, createdAt: 130, updatedAt: 130)
        }

        let rows = try db.read { try ChatConversationQueries.fetchAllByContext($0, type: "target", id: "7") }
        XCTAssertEqual(rows.map(\.title), ["mine"])
    }

    func testFetchAllByContextEmptyWhenNone() throws {
        let db = try makeDB()
        let rows = try db.read { try ChatConversationQueries.fetchAllByContext($0, type: "target", id: "7") }
        XCTAssertTrue(rows.isEmpty)
    }

    /// The pre-existing single-row reader keeps its own (updated_at DESC)
    /// contract — callers still depend on it.
    func testFetchByContextStillReturnsMostRecentlyUpdated() throws {
        let db = try makeDB()
        try db.write { db in
            try insert(db, title: "first", createdAt: 100, updatedAt: 100)
            try insert(db, title: "second", createdAt: 200, updatedAt: 900)
        }
        let one = try db.read { try ChatConversationQueries.fetchByContext($0, type: "target", id: "7") }
        XCTAssertEqual(one?.title, "second")
    }

    // MARK: - latestTurnActivity

    func testLatestTurnActivityIsMaxAcrossConversations() throws {
        let db = try makeDB()
        try db.write { db in
            let a = try insert(db, title: "a", createdAt: 100, updatedAt: 100)
            let b = try insert(db, title: "b", createdAt: 200, updatedAt: 200)
            try insertMessage(db, conversationID: a, createdAt: 300)
            try insertMessage(db, conversationID: b, createdAt: 1_700_000_000)
            try insertMessage(db, conversationID: b, role: "assistant", createdAt: 900)
        }

        let newest = try db.read { try ChatConversationQueries.latestTurnActivity($0, type: "target", id: "7") }
        XCTAssertEqual(newest, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testLatestTurnActivityNilWhenNoConversations() throws {
        let db = try makeDB()
        try db.write { db in
            let other = try insert(db, title: "other target", contextID: "8", createdAt: 100, updatedAt: 100)
            try insertMessage(db, conversationID: other, createdAt: 500)
        }
        let newest = try db.read { try ChatConversationQueries.latestTurnActivity($0, type: "target", id: "7") }
        XCTAssertNil(newest)
    }

    /// The regression this reader exists for: merely opening a tab (a row with a
    /// fresh `updated_at` and no messages) is NOT activity, so it can never light
    /// the "context changed" badge on a target nobody has chatted with.
    func testOpeningATabIsNotActivity() throws {
        let db = try makeDB()
        let now = Date().timeIntervalSince1970
        try db.write { db in
            _ = try insert(db, title: "New chat", createdAt: now, updatedAt: now)
        }
        let newest = try db.read { try ChatConversationQueries.latestTurnActivity($0, type: "target", id: "7") }
        XCTAssertNil(newest)
    }

    /// Same for renaming (or any other `touch`): the conversation stamp moves,
    /// the activity does not.
    func testRenamingATabIsNotActivity() throws {
        let db = try makeDB()
        let id = try db.write { db in
            try insert(db, title: "New chat", createdAt: 100, updatedAt: 100)
        }
        try db.write { db in
            try ChatConversationQueries.updateTitle(db, id: id, title: "renamed")
            try ChatConversationQueries.touch(db, id: id)
        }
        let newest = try db.read { try ChatConversationQueries.latestTurnActivity($0, type: "target", id: "7") }
        XCTAssertNil(newest)
    }

    /// A user turn counts on its own — the assistant's reply (the only writer
    /// that calls `touch`) may never arrive.
    func testAUserTurnAloneIsActivity() throws {
        let db = try makeDB()
        try db.write { db in
            let id = try insert(db, title: "a", createdAt: 100, updatedAt: 100)
            try insertMessage(db, conversationID: id, role: "user", createdAt: 555)
        }
        let newest = try db.read { try ChatConversationQueries.latestTurnActivity($0, type: "target", id: "7") }
        XCTAssertEqual(newest, Date(timeIntervalSince1970: 555))
    }
}
