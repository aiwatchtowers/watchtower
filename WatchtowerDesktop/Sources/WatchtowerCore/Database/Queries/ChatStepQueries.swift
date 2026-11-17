import Foundation
import GRDB

/// `chat_turn_steps` — every tool call of a turn, persisted as it happens
/// (CHAT-02). Keyed by `(message_id, tool_id)` without relying on a UNIQUE
/// index, so a repeated `tool_start` updates rather than duplicates.
package enum ChatStepQueries {

    package static func fetch(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [ChatTurnStep]] {
        guard !messageIDs.isEmpty else { return [:] }
        let steps = try ChatTurnStep.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_turn_steps WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count)))
                ORDER BY message_id, seq, id
                """,
            arguments: StatementArguments(messageIDs)
        )
        return Dictionary(grouping: steps, by: \.messageID)
    }
}
