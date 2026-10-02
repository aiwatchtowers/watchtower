import GRDB

package enum AgentActionQueries {
    /// NULL-safe filter shared by every strip/badge reader: a project's
    /// direct-apply audit rows are not owner decisions (STRIP-01). An External
    /// project row is the exception — DEV-06 refuses every External tool
    /// inline, so it is a propose-only proposal (a Slack send from the project
    /// terminal) that waits for the owner's Approve here.
    private static let notProjectRow = "(context_type IS NOT 'project' OR external = 1)"

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

    /// How many proposals wait on the owner right now: pending ones and failed
    /// ones (retriable). Drives the Inbox sidebar badge; `approved`/`executing`
    /// rows are in flight, not decisions, so they are not counted. Project
    /// rows are excluded like in `fetchStrip` (STRIP-01).
    package static func awaitingOwnerCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM agent_actions
            WHERE status IN ('pending','failed') AND \(notProjectRow)
            """) ?? 0
    }

    /// Every non-terminal proposal across every conversation, newest first,
    /// PLUS a bounded tail of recently applied/rejected rows (`decided_at >=
    /// terminalSince`, an RFC3339 UTC string) so an execute-trust tool's
    /// result — `brief_context` above all, which never has a non-terminal
    /// state to be caught in — actually surfaces on the strip instead of
    /// vanishing the instant it auto-applies (spec §4.1). Non-terminal rows
    /// sort first, then the terminal tail, newest-first within each group.
    ///
    /// Project rows (`context_type = 'project'`) are the audit trail of the
    /// project agent's direct MCP writes, never an owner gesture, so they
    /// stay off the strip (STRIP-01) — except an External one, which is a
    /// proposal awaiting the owner (`notProjectRow`).
    package static func fetchStrip(_ db: Database, terminalSince: String) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE (status IN ('pending','approved','failed','executing')
                   OR (status IN ('applied','rejected') AND decided_at >= ?))
              AND \(notProjectRow)
            ORDER BY (status IN ('applied','rejected')) ASC, created_at DESC, id DESC
            """, arguments: [terminalSince])
    }
}
