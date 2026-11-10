import GRDB

package enum AgentActionQueries {
    /// NULL-safe filter shared by every strip/badge reader: a project's
    /// direct-apply audit rows are not owner decisions (STRIP-01). An External
    /// workbench row is the exception — DEV-06 refuses every External tool
    /// inline, so it is a propose-only proposal (a Slack send from the workbench
    /// terminal) that waits for the owner's Approve here.
    /// The Inbox's one-press tool (`surface = 'inbox' AND tool = 'apply_track_action'`,
    /// proposed and approved by the same press) is excluded too; every other
    /// inbox row — a card's target button (`create_target`), a Reply — waits
    /// for the owner's Approve and stays (STRIP-01 narrowing, ask #451; Go's
    /// `approvalRowClause` in `internal/db/approvals.go` is the twin).
    private static let notWorkbenchRow = "((context_type IS NOT 'project' OR external = 1)"
        + " AND NOT (surface = 'inbox' AND tool = 'apply_track_action'))"

    /// A failed session-applied call (`claude_ai_connector_call`, Go
    /// `Tool.AppliedBySession`) has no Retry: Apply refuses it. It is terminal
    /// for the badge and the strip — except an unknown outcome the owner has
    /// not dismissed yet (`ConnectorCallProposal.awaitsDismissal`, ask #342),
    /// which waits on the owner like a pending proposal. Both constants are
    /// fixed strings without a quote, so interpolating them is safe.
    private static let settledSessionCall = "(status = 'failed' AND tool = '\(ConnectorCallProposal.tool)'"
        + " AND NOT (error = '\(ConnectorCallProposal.sessionEndedWhileRunning)' AND dismissed_at = ''))"

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

    /// One row by id; nil when it is gone.
    package static func fetch(_ db: Database, id: Int64) throws -> AgentAction? {
        try AgentAction.fetchOne(db, sql: "SELECT * FROM agent_actions WHERE id = ?", arguments: [id])
    }

    /// The row's `context_type`; nil when the row is gone.
    package static func contextType(_ db: Database, id: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT context_type FROM agent_actions WHERE id = ?", arguments: [id])
    }

    /// How many proposals wait on the owner right now: pending ones and failed
    /// ones (retriable, or a session call whose unknown outcome is not
    /// dismissed yet — any other failed session call is settled). Drives the
    /// Inbox sidebar badge; `approved`/`executing` rows are in flight, not
    /// decisions, so they are not counted. Project rows are excluded like in
    /// `fetchStrip` (STRIP-01).
    package static func awaitingOwnerCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agent_actions WHERE \(awaitingOwnerClause)") ?? 0
    }

    /// The `agent_actions` rows that wait on the owner, as an unqualified
    /// WHERE clause with no `?`: `awaitingOwnerCount`'s predicate, shared with
    /// the Inbox's render-time check of an `action` ref (`InboxRefState`).
    package static let awaitingOwnerClause =
        "status IN ('pending','failed') AND \(notWorkbenchRow) AND NOT \(settledSessionCall)"

    /// The rows `awaitingOwnerCount` counts (pending/failed, `notWorkbenchRow`), newest first.
    package static func awaitingOwner(_ db: Database, limit: Int) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions WHERE \(awaitingOwnerClause)
            ORDER BY created_at DESC, id DESC
            LIMIT ?
            """, arguments: [limit])
    }

    /// Every non-terminal proposal across every conversation, newest first,
    /// PLUS a bounded tail of recently applied/rejected rows (`decided_at >=
    /// terminalSince`, an RFC3339 UTC string) so an execute-trust tool's
    /// result — `brief_context` above all, which never has a non-terminal
    /// state to be caught in — actually surfaces on the strip instead of
    /// vanishing the instant it auto-applies (spec §4.1). Non-terminal rows
    /// sort first, then the terminal tail, newest-first within each group.
    ///
    /// A settled failed session call (no Retry) belongs to the terminal tail,
    /// by the time it failed (`applied_at`) or was dismissed (`dismissed_at`,
    /// so a Dismiss does not make an old row vanish at once); an undismissed
    /// unknown outcome sorts with the non-terminal rows until then.
    ///
    /// Project rows (`context_type = 'project'`) are the audit trail of the
    /// project agent's direct MCP writes, never an owner gesture, so they
    /// stay off the strip (STRIP-01) — except an External one, which is a
    /// proposal awaiting the owner (`notWorkbenchRow`). The Inbox's one-press
    /// rows (`apply_track_action` on the `inbox` surface, proposed and
    /// approved by one press) are not proposals either: they leave no
    /// decision to make. A target-button or Reply row on that surface is.
    package static func fetchStrip(_ db: Database, terminalSince: String) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE ((status IN ('pending','approved','failed','executing') AND NOT \(settledSessionCall))
                   OR (status IN ('applied','rejected') AND decided_at >= ?)
                   OR (\(settledSessionCall) AND (applied_at >= ? OR dismissed_at >= ?)))
              AND \(notWorkbenchRow)
            ORDER BY (status IN ('applied','rejected') OR \(settledSessionCall)) ASC, created_at DESC, id DESC
            """, arguments: [terminalSince, terminalSince, terminalSince])
    }

    /// The tool of the `:brief:` reaction: a thread brief, applied at once.
    package static let briefTool = "brief_context"

    /// The thread briefs (`brief_context`) applied at or after `since` (an
    /// RFC3339 UTC string, the column format), newest applied first: each is
    /// an entry of the Inbox root for 24 hours (ask #609). A result, never an
    /// approval: nothing counts them. Project rows are left out as on the
    /// strip (STRIP-01).
    package static func fetchExecutedBriefs(_ db: Database, since: String) throws -> [AgentAction] {
        try AgentAction.fetchAll(db, sql: """
            SELECT * FROM agent_actions
            WHERE tool = ? AND status = 'applied' AND applied_at >= ? AND \(notWorkbenchRow)
            ORDER BY applied_at DESC, id DESC
            """, arguments: [briefTool, since])
    }

    /// The newest proposal of each Inbox target button (`context_type =
    /// 'automation_output'`, `context_id = '<output>:<index>:<hash>'`) whose
    /// output is one of `outputIDs` or whose context is one of `contextIDs`,
    /// keyed by context id. Newest = highest id: a context's rows are
    /// written one at a time (one open row per context, Go AGENT-05).
    package static func newestButtonProposals(
        _ db: Database, outputIDs: [Int64], contextIDs: [String]
    ) throws -> [String: AgentAction] {
        var terms: [String] = []
        var arguments = StatementArguments()
        if !outputIDs.isEmpty {
            terms.append("CAST(substr(a.context_id, 1, instr(a.context_id, ':') - 1) AS INTEGER) IN "
                + placeholders(outputIDs.count))
            arguments += StatementArguments(outputIDs)
        }
        if !contextIDs.isEmpty {
            terms.append("a.context_id IN " + placeholders(contextIDs.count))
            arguments += StatementArguments(contextIDs)
        }
        guard !terms.isEmpty else { return [:] }
        // One pass, newest first, the first row per context kept: no
        // correlated subquery per row. No index covers (context_type,
        // context_id) for every status (`idx_agent_actions_open_context` is
        // partial, open rows only), so this reads the table once per refresh.
        let rows = try AgentAction.fetchAll(db, sql: """
            SELECT a.* FROM agent_actions a
            WHERE a.context_type = '\(buttonContextType)' AND (\(terms.joined(separator: " OR ")))
            ORDER BY a.id DESC
            """, arguments: arguments)
        return Dictionary(rows.map { ($0.contextID, $0) }) { newer, _ in newer }
    }

    /// Of `actionIDs`, the rows whose task still exists, row id → task id:
    /// `create_target` writes its task with `source_type = 'chat'`,
    /// `source_id = 'action:<row id>'` (Go `CreateTargetForAction`; one per
    /// row, `idx_targets_action_source`).
    package static func actionsWithTask(_ db: Database, actionIDs: [Int64]) throws -> [Int64: Int64] {
        guard !actionIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, source_id FROM targets
            WHERE source_type = 'chat' AND source_id IN \(placeholders(actionIDs.count))
            """, arguments: StatementArguments(actionIDs.map { "action:\($0)" }))
        var out: [Int64: Int64] = [:]
        for row in rows {
            let source: String = row["source_id"]
            guard let actionID = Int64(source.dropFirst("action:".count)) else { continue }
            out[actionID] = row["id"]
        }
        return out
    }

    /// The context type of an Inbox target button's proposal.
    package static let buttonContextType = "automation_output"

    private static func placeholders(_ count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ",") + ")"
    }
}
