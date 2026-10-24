import Foundation
import GRDB

/// `instruction_chat_lines`: the lines the owner told the chat to remember.
/// The chat reads the rows its messages produced to show "Remembered" under
/// them; writes are the CLI's (`instructions remember|forget`).
package enum InstructionChatLineQueries {
    /// The line stored for each of the given messages, keyed by message id.
    /// Several rows for one message cannot happen (one message, one command);
    /// the newest wins if it ever does. Messages without a row are absent.
    package static func forMessages(_ db: Database, ids: [Int64]) throws -> [Int64: OwnerInstructionChatLine] {
        guard !ids.isEmpty else { return [:] }
        let marks = databaseQuestionMarks(count: ids.count)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, line, conversation_id, message_id, added_at
                FROM instruction_chat_lines
                WHERE message_id IN (\(marks))
                ORDER BY id
                """,
            arguments: StatementArguments(ids)
        )
        var result: [Int64: OwnerInstructionChatLine] = [:]
        for row in rows {
            guard let messageID: Int64 = row["message_id"] else { continue }
            result[messageID] = OwnerInstructionChatLine(
                id: row["id"], line: row["line"], conversationID: row["conversation_id"],
                messageID: messageID, addedAt: row["added_at"]
            )
        }
        return result
    }
}
