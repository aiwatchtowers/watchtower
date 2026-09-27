import Foundation
import GRDB

package enum ChatMessageQueries {
    package static func fetchByConversation(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY created_at ASC
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
}
