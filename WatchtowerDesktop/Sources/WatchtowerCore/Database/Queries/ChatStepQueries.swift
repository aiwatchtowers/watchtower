import Foundation
import GRDB

/// `chat_turn_steps` — every tool call of a turn, persisted as it happens
/// (CHAT-02). Keyed by `(message_id, tool_id)` without relying on a UNIQUE
/// index, so a repeated `tool_start` updates rather than duplicates.
package enum ChatStepQueries {
    package static func upsertStart(
        _ db: Database, messageID: Int64, seq: Int, toolID: String, name: String, argsJSON: String, startedAt: Double
    ) throws {
        if let existing = try Int64.fetchOne(
            db, sql: "SELECT id FROM chat_turn_steps WHERE message_id = ? AND tool_id = ?", arguments: [messageID, toolID]
        ) {
            try db.execute(
                sql: "UPDATE chat_turn_steps SET name = ?, args_json = ?, started_at = ? WHERE id = ?",
                arguments: [name, argsJSON, startedAt, existing]
            )
            return
        }
        try db.execute(sql: """
            INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, args_json, started_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [messageID, seq, toolID, name, argsJSON, startedAt])
    }

    package static func finish(
        _ db: Database, messageID: Int64, toolID: String, ok: Bool, summary: String, sourcesJSON: String, endedAt: Double
    ) throws {
        try db.execute(sql: """
            UPDATE chat_turn_steps SET ok = ?, summary = ?, sources_json = ?, ended_at = ?
            WHERE message_id = ? AND tool_id = ?
            """, arguments: [ok ? 1 : 0, summary, sourcesJSON, endedAt, messageID, toolID])
        guard db.changesCount == 0 else { return }
        // A tool_end whose tool_start never arrived is still a visible step (CHAT-02).
        let seq = try Int.fetchOne(
            db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM chat_turn_steps WHERE message_id = ?", arguments: [messageID]
        ) ?? 0
        try db.execute(sql: """
            INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, sources_json, started_at, ended_at)
            VALUES (?, ?, ?, '', ?, ?, ?, ?, ?)
            """, arguments: [messageID, seq, toolID, ok ? 1 : 0, summary, sourcesJSON, endedAt, endedAt])
    }

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
