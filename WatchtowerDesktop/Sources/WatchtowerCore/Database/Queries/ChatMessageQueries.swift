import Foundation
import GRDB

package enum ChatMessageQueries {
    package static func fetchByConversation(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY created_at ASC, id ASC
                """,
            arguments: [conversationID]
        )
    }

    @discardableResult
    package static func insert(_ db: Database, conversationID: Int64, role: String, text: String, turnID: String = "") throws -> Int64 {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, ?, ?, ?, ?)
        """, arguments: [conversationID, role, text, now, turnID])
        return db.lastInsertedRowID
    }

    package static func deleteByConversation(_ db: Database, conversationID: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_messages WHERE conversation_id = ?", arguments: [conversationID])
    }

    // MARK: - Embedded chats (one `ai query` per turn)

    /// The owner row (when there is one) and the reply's empty `partial`
    /// placeholder, in one transaction — the owner text is on disk before the
    /// turn is sent. Throws `ChatContextGoneError` when the conversation is gone.
    package static func beginEmbeddedTurn(
        _ db: Database, conversationID: Int64, ownerText: String?, turnID: String, now: Double
    ) throws -> (ownerID: Int64?, assistantID: Int64) {
        try requireConversation(db, id: conversationID)
        var ownerID: Int64?
        if let ownerText {
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, 'user', ?, ?, ?)
                """, arguments: [conversationID, ownerText, now, turnID])
            ownerID = db.lastInsertedRowID
        }
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id, status)
            VALUES (?, 'assistant', '', ?, ?, 'partial')
            """, arguments: [conversationID, now, turnID])
        return (ownerID, db.lastInsertedRowID)
    }

    /// Streamed text so far; the row stays `partial`.
    package static func saveEmbeddedProgress(_ db: Database, messageID: Int64, text: String) throws {
        try db.execute(sql: "UPDATE chat_messages SET text = ? WHERE id = ?", arguments: [text, messageID])
        guard db.changesCount > 0 else { throw ChatContextGoneError() }
    }

    package static func finalizeEmbedded(
        _ db: Database, messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?
    ) throws {
        try db.execute(sql: """
            UPDATE chat_messages SET text = ?, status = ?, error_code = ?, error_message = ? WHERE id = ?
            """, arguments: [text, status, errorCode, errorMessage, messageID])
        guard db.changesCount > 0 else { throw ChatContextGoneError() }
    }

    package static func requireConversation(_ db: Database, id: Int64) throws {
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM chat_conversations WHERE id = ?)",
                                       arguments: [id]) ?? false
        guard exists else { throw ChatContextGoneError() }
    }
}

/// The chat's conversation (or the row being written) no longer exists —
/// its target/track/idea was deleted, taking the conversation with it.
package struct ChatContextGoneError: LocalizedError, Equatable {
    package init() {}
    package var errorDescription: String? { "This chat no longer exists." }
}
