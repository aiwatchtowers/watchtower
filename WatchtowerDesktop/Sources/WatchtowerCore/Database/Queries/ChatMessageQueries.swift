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

    // MARK: - Embedded chats (one `ai query` per turn)

}

/// The chat's conversation (or the row being written) no longer exists —
/// its target/track/idea was deleted, taking the conversation with it.
package struct ChatContextGoneError: LocalizedError, Equatable {
    package init() {}
    package var errorDescription: String? { "This chat no longer exists." }
}
