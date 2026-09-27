import Foundation
import GRDB

extension TestDatabase {
    /// One `chat_conversations` row. Columns not listed keep their schema
    /// defaults; tests that need `archived_at`/`title_source`/leaf set them
    /// with a direct UPDATE so this helper stays under the parameter limit.
    @discardableResult
    package static func insertChatConversation(
        _ db: Database,
        title: String = "",
        sessionID: String? = nil,
        contextType: String? = nil,
        provider: String? = nil,
        updatedAt: Double = Date().timeIntervalSince1970,
        pinned: Bool = false
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, session_id, context_type, provider, created_at, updated_at, pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [title, sessionID, contextType, provider, updatedAt, updatedAt, pinned ? 1 : 0])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertChatMessage(
        _ db: Database,
        conversationID: Int64,
        role: String,
        text: String,
        parentID: Int64? = nil,
        status: String = "complete",
        turnID: String = "",
        createdAt: Double = Date().timeIntervalSince1970
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, parent_id, status, turn_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, role, text, parentID, status, turnID, createdAt])
        return db.lastInsertedRowID
    }
}
