import GRDB

package enum AgentActionQueries {
    /// Every proposal of one conversation, oldest first — the feed's
    /// observation query.
    package static func fetchByConversation(_ db: Database, conversationID: Int64) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions WHERE conversation_id = ?
            ORDER BY created_at ASC, id ASC
            """, arguments: [conversationID])
    }

    /// Proposals decided or executed after `after` (an RFC3339 UTC string —
    /// the column format, so a string compare is a time compare). Feeds the
    /// "actions since your last message" block.
    package static func fetchDecidedAfter(_ db: Database, conversationID: Int64, after: String) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE conversation_id = ? AND (decided_at > ? OR applied_at > ?)
            ORDER BY created_at ASC, id ASC
            """, arguments: [conversationID, after, after])
    }
}
