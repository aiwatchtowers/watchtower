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

    /// Proposals decided or executed at-or-after `after` (an RFC3339 UTC
    /// string — the column format, so a string compare is a time compare).
    /// Feeds the "actions since your last message" block.
    ///
    /// `>=`, not `>`: `after` is a whole-second floor of a sub-second `Date`
    /// (`AgentActionFeed.timestampString`), so a row decided in that same
    /// second — after the floor moment but truncated to it — must still be
    /// reported. The cost is at most reporting again a row truly decided
    /// earlier in the floor's second, which is noise, not loss; `>` would
    /// drop a same-second row forever, since every later floor is later
    /// still.
    package static func fetchDecidedAfter(_ db: Database, conversationID: Int64, after: String) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE conversation_id = ? AND (decided_at >= ? OR applied_at >= ?)
            ORDER BY created_at ASC, id ASC
            """, arguments: [conversationID, after, after])
    }
}
