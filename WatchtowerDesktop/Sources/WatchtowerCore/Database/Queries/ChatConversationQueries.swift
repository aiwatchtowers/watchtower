import Foundation
import GRDB

package enum ChatConversationQueries {
    package static func ensureTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS chat_conversations (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL DEFAULT '',
                session_id TEXT,
                context_type TEXT,
                context_id TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
        """)
    }

    package static func fetchAll(_ db: Database) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT * FROM chat_conversations ORDER BY updated_at DESC
        """)
    }

    package static func fetchStandalone(_ db: Database) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT * FROM chat_conversations WHERE context_type IS NULL ORDER BY updated_at DESC
        """)
    }

    package static func search(_ db: Database, query: String) throws -> [ChatConversation] {
        let pattern = "%\(query)%"
        return try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_conversations WHERE context_type IS NULL AND title LIKE ? ORDER BY updated_at DESC
                """,
            arguments: [pattern]
        )
    }

    package static func ensureContextColumns(_ db: Database) throws {
        let columns = try db.columns(in: "chat_conversations").map(\.name)
        if !columns.contains("context_type") {
            try db.execute(sql: "ALTER TABLE chat_conversations ADD COLUMN context_type TEXT")
            // Fresh column — no migration needed.
            if !columns.contains("context_id") {
                try db.execute(sql: "ALTER TABLE chat_conversations ADD COLUMN context_id TEXT")
            }
            return
        }
        if !columns.contains("context_id") {
            try db.execute(sql: "ALTER TABLE chat_conversations ADD COLUMN context_id TEXT")
        }
        // One-time migration: rename old "action_item" context type to "track".
        try db.execute(sql: "UPDATE chat_conversations SET context_type = 'track' WHERE context_type = 'action_item'")
    }

    @discardableResult
    package static func create(_ db: Database, title: String = "", contextType: String? = nil, contextID: String? = nil) throws -> ChatConversation {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
        """, arguments: [title, contextType, contextID, now, now])
        let rowID = db.lastInsertedRowID
        guard let conversation = try ChatConversation.fetchOne(db, sql: "SELECT * FROM chat_conversations WHERE id = ?", arguments: [rowID]) else {
            throw DatabaseError(message: "Failed to fetch newly created chat conversation")
        }
        return conversation
    }

    package static func fetchByContext(_ db: Database, type: String, id: String) throws -> ChatConversation? {
        try ChatConversation.fetchOne(
            db,
            sql: """
                SELECT * FROM chat_conversations WHERE context_type = ? AND context_id = ? ORDER BY updated_at DESC LIMIT 1
                """,
            arguments: [type, id]
        )
    }

    /// All conversations for one context, oldest first — the tab order on the
    /// target assistant. `id` breaks ties so two rows created inside the same
    /// `Date()` tick keep a stable order.
    package static func fetchAllByContext(_ db: Database, type: String, id: String) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_conversations
                WHERE context_type = ? AND context_id = ?
                ORDER BY created_at ASC, id ASC
                """,
            arguments: [type, id]
        )
    }

    /// When this context last had a real chat TURN, or nil when it has had none.
    ///
    /// Deliberately measured over `chat_messages`, not over the conversations'
    /// own `updated_at`: a row's stamp moves when the tab is merely created or
    /// renamed, so a `MAX(updated_at)` would report "activity" for an empty tab
    /// the operator just opened. It also lags a real turn — only the assistant's
    /// reply calls `touch`, so a user turn whose reply failed would report none.
    /// Every persisted message (user, assistant and the "Action applied: …"
    /// system lines) counts, and only those.
    ///
    /// `created_at` is a REAL unix timestamp in these Swift-owned tables, so the
    /// raw MAX is seconds since 1970. `chat_messages` is created by the Desktop
    /// module alongside `chat_conversations`; a caller running before either
    /// exists gets the thrown "no such table", which reads as "no activity".
    package static func latestTurnActivity(_ db: Database, type: String, id: String) throws -> Date? {
        let newest = try Double.fetchOne(
            db,
            sql: """
                SELECT MAX(m.created_at) FROM chat_messages m
                JOIN chat_conversations c ON c.id = m.conversation_id
                WHERE c.context_type = ? AND c.context_id = ?
                """,
            arguments: [type, id]
        )
        guard let newest else { return nil }
        return Date(timeIntervalSince1970: newest)
    }

    package static func updateTitle(_ db: Database, id: Int64, title: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET title = ?, updated_at = ? WHERE id = ?
        """, arguments: [title, now, id])
    }

    package static func updateSessionID(_ db: Database, id: Int64, sessionID: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET session_id = ?, updated_at = ? WHERE id = ?
        """, arguments: [sessionID, now, id])
    }

    package static func touch(_ db: Database, id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET updated_at = ? WHERE id = ?
        """, arguments: [now, id])
    }

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [id])
    }

    package static func fetchByID(_ db: Database, id: Int64) throws -> ChatConversation? {
        try ChatConversation.fetchOne(db, sql: "SELECT * FROM chat_conversations WHERE id = ?", arguments: [id])
    }
}
