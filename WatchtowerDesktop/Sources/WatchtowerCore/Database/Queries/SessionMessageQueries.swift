import GRDB

/// Reads of `session_messages` (00196). Read-only: MCP inserts, the daemon
/// delivers, and the Desktop's one change (the prompt-flag Dismiss) goes
/// through `WorkbenchCLI.messageDismiss`.
package enum SessionMessageQueries {
    /// The sessions among `sessionIDs` whose prompt may still hold an agent's
    /// message: a delivered `typed_not_submitted` row not cleared yet (Go
    /// `db.UnclearedPromptMessages`).
    package static func waitingInPrompt(_ db: Database, sessionIDs: [Int64]) throws -> Set<Int64> {
        guard !sessionIDs.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        var arguments = StatementArguments([SessionMessage.typedNotSubmitted])
        arguments += StatementArguments(sessionIDs)
        return Set(try Int64.fetchAll(db, sql: """
            SELECT DISTINCT to_session_id FROM session_messages
            WHERE state = 'delivered' AND reason = ? AND prompt_cleared_at IS NULL
              AND to_session_id IN (\(marks))
            """, arguments: arguments))
    }

    /// The messages `fromSessionID` sent that still wait for delivery, oldest first.
    package static func queued(_ db: Database, fromSessionID: Int64) throws -> [SessionMessage] {
        try SessionMessage.fetchAll(db, sql: """
            SELECT id, workbench_id, from_session_id, to_session_id, kind, text, created_at, state, reason,
                   delivered_at, prompt_cleared_at
            FROM session_messages WHERE from_session_id = ? AND state = 'queued' ORDER BY id
            """, arguments: [fromSessionID])
    }
}
