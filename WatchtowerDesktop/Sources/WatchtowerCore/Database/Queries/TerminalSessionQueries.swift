import Foundation
import GRDB

package enum TerminalSessionQueryError: LocalizedError, Equatable {
    case emptyTitle
    case notFound(Int64)
    case missingSessionID

    package var errorDescription: String? {
        switch self {
        case .emptyTitle: "A session needs a name."
        case let .notFound(id): "Terminal session \(id) no longer exists."
        case .missingSessionID: "A Claude Code session needs a session id."
        }
    }
}

/// Embedded terminal sessions (spec 2026-09-30-project-workspace-sessions).
/// The Desktop owns every write except the AI title, which Go writes with
/// `title_source = 'ai'`.
package enum TerminalSessionQueries {
    private static let now = "strftime('%Y-%m-%dT%H:%M:%SZ','now')"

    package struct NewSession: Sendable {
        package var projectID: Int64?
        package var kind: TerminalSession.Kind
        package var title: String
        package var targetID: Int64?
        package var folderPath: String
        /// The agent's own session id. Required (non-empty) for `.claude`;
        /// nil for a shell, and for a new codex row (Codex mints its id).
        package var claudeSessionID: String?
        /// Set when Watchtower created the session's worktree (00113).
        package var worktreeBranch: String?
        package var worktreeBase: String?

        package init(
            projectID: Int64?,
            kind: TerminalSession.Kind,
            title: String,
            targetID: Int64? = nil,
            folderPath: String,
            claudeSessionID: String? = nil,
            worktreeBranch: String? = nil,
            worktreeBase: String? = nil
        ) {
            self.projectID = projectID
            self.kind = kind
            self.title = title
            self.targetID = targetID
            self.folderPath = folderPath
            self.claudeSessionID = claudeSessionID
            self.worktreeBranch = worktreeBranch
            self.worktreeBase = worktreeBase
        }
    }

    /// Throws `missingSessionID` for a `.claude` row without a session id
    /// (the schema's CHECK would reject a NULL one; an empty one too, here).
    package static func create(_ db: Database, _ new: NewSession) throws -> TerminalSession {
        if new.kind == .claude, new.claudeSessionID?.isEmpty ?? true {
            throw TerminalSessionQueryError.missingSessionID
        }
        try db.execute(
            sql: """
                INSERT INTO terminal_sessions
                    (project_id, kind, title, target_id, folder_path, claude_session_id,
                     worktree_branch, worktree_base)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                new.projectID, new.kind.rawValue, new.title, new.targetID, new.folderPath,
                new.claudeSessionID, new.worktreeBranch, new.worktreeBase
            ]
        )
        let id = db.lastInsertedRowID
        guard let row = try fetch(db, id: id) else { throw TerminalSessionQueryError.notFound(id) }
        return row
    }

    package static func fetch(_ db: Database, id: Int64) throws -> TerminalSession? {
        try TerminalSession.fetchOne(db, sql: "SELECT * FROM terminal_sessions WHERE id = ?", arguments: [id])
    }

    /// Whether row `id`'s agent called `finish_session` and has not worked
    /// since (`finished_at` set; Go clears it on any `working` write). False
    /// for a missing row. Read-only: Go writes the column.
    package static func isFinished(_ db: Database, id: Int64) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT finished_at IS NOT NULL FROM terminal_sessions WHERE id = ?", arguments: [id]
        ) ?? false
    }

    package static func fetchForWorkbench(_ db: Database, projectID: Int64) throws -> [TerminalSession] {
        try TerminalSession.fetchAll(
            db,
            sql: "SELECT * FROM terminal_sessions WHERE project_id = ? ORDER BY last_active_at DESC, id DESC",
            arguments: [projectID]
        )
    }

    /// Every workbench's sessions, most recently active first — the ⌘K
    /// palette's data (board #252). Standalone terminals are left out.
    package static func fetchAllWorkbenchSessions(_ db: Database) throws -> [TerminalSession] {
        try TerminalSession.fetchAll(
            db,
            sql: "SELECT * FROM terminal_sessions WHERE project_id IS NOT NULL ORDER BY last_active_at DESC, id DESC"
        )
    }

    package static func fetchStandalone(_ db: Database) throws -> [TerminalSession] {
        try TerminalSession.fetchAll(
            db,
            sql: "SELECT * FROM terminal_sessions WHERE project_id IS NULL ORDER BY last_active_at DESC, id DESC"
        )
    }

    package static func fetchForTarget(_ db: Database, targetID: Int64) throws -> [TerminalSession] {
        try TerminalSession.fetchAll(
            db,
            sql: "SELECT * FROM terminal_sessions WHERE target_id = ? ORDER BY last_active_at DESC, id DESC",
            arguments: [targetID]
        )
    }

    /// The stored state of every workbench agent session (`claude` or
    /// `codex`), live or not, plus `liveIDs` (a live standalone agent terminal): the hook state,
    /// finished, the error, the background agent count and its report, the
    /// recorded Chat question and its stamp, the open-ask count, its
    /// questions and reviews (#534) and the oldest open ask, with the
    /// workbench name a notice names, and the stamp of the stored working
    /// directory (NULL without migration 00110; the column probe is
    /// `fetchAgentCwds`', with its `DatabasePool.read` rule). Read-only: Go
    /// writes these columns.
    package static func fetchAgentStates(_ db: Database, liveIDs: [Int64]) throws -> [SessionAgentStateRow] {
        let marks = liveIDs.isEmpty ? "NULL" : databaseQuestionMarks(count: liveIDs.count)
        let cwdAt = try hasAgentCwd(db) ? "s.agent_cwd_at" : "NULL"
        return try SessionAgentStateRow.fetchAll(
            db,
            sql: """
                SELECT s.id, s.project_id, s.title, s.agent_state, s.agent_state_at, p.name AS workbench_name,
                       s.finished_at, s.finish_summary, s.agent_failed_at, s.agent_error,
                       s.agent_background, s.agent_background_at, s.chat_question, s.chat_question_at,
                       \(cwdAt) AS agent_cwd_at,
                       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = s.id AND a.status = 'open') AS open_asks,
                       (SELECT MIN(a.id) FROM owner_asks a WHERE a.session_id = s.id AND a.status = 'open')
                           AS oldest_open_ask_id,
                       (SELECT COUNT(*) FROM owner_asks a
                        WHERE a.session_id = s.id AND a.status = 'open' AND a.kind = 'question') AS open_question_asks,
                       (SELECT COUNT(*) FROM owner_asks a
                        WHERE a.session_id = s.id AND a.status = 'open' AND a.kind = 'review') AS open_review_asks
                FROM terminal_sessions s
                LEFT JOIN projects p ON p.id = s.project_id
                WHERE (s.kind IN \(AgentKind.sqlKinds) AND s.project_id IS NOT NULL) OR s.id IN (\(marks))
                ORDER BY s.id
                """,
            arguments: StatementArguments(liveIDs)
        )
    }

    /// The recorded main-agent working directory of workbench `projectID`'s
    /// rows that have one (board #565), by session id, with each row's run
    /// start read as Go's `db.TerminalAgentCwd` reads it (`agent_turns`'
    /// `since`, NULL unless the column is JSON). Read-only: Go's hooks write
    /// them. Kept out of `TerminalSession` and its `SELECT *` readers, as Go
    /// keeps them out of `GetTerminalSession`: a database without migration
    /// 00110 yields no cwds rather than failing anything else. The column
    /// probe costs one `PRAGMA table_xinfo` per connection, not per reload:
    /// GRDB caches it per connection. Call it only inside `DatabasePool.read`:
    /// a pool reader drops that cache when the schema version moved, so a
    /// database the daemon migrates while the app runs gets its cwds on the
    /// next read. The writer connection (`write`) or a `DatabaseQueue` does
    /// not notice another process's migration and would keep answering
    /// `[:]` until the app restarts.
    package static func fetchAgentCwds(_ db: Database, projectID: Int64) throws -> [Int64: SessionAgentCwd] {
        guard try hasAgentCwd(db) else { return [:] }
        let rows = try SessionAgentCwd.fetchAll(
            db,
            sql: """
                SELECT id, agent_cwd, agent_cwd_at,
                       CASE WHEN json_valid(agent_turns) THEN json_extract(agent_turns, '$.since') END AS run_start
                FROM terminal_sessions
                WHERE project_id = ? AND agent_cwd IS NOT NULL
                """,
            arguments: [projectID]
        )
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.sessionID, $0) })
    }

    /// Whether the database has migration 00110's cwd columns (GRDB caches
    /// the probe per connection).
    private static func hasAgentCwd(_ db: Database) throws -> Bool {
        try db.columns(in: "terminal_sessions").contains { $0.name == "agent_cwd_at" }
    }

    /// Session `id`'s stored cleanup outcome (board #535, migration 00111):
    /// `cleanup_result` decoded tolerantly (an undecodable one is a record
    /// with a nil result) and `cleanup_at`. Nil when the row is gone, has no
    /// result yet, or the database predates 00111. Read-only: Go writes the
    /// columns. Kept out of `TerminalSession` and its `SELECT *` readers, as
    /// Go keeps them out of `GetTerminalSession`; the column probe and its
    /// `DatabasePool.read` rule are `fetchAgentCwds`'.
    package static func fetchCleanupRecord(_ db: Database, sessionID: Int64) throws -> SessionCleanupRecord? {
        guard try db.columns(in: "terminal_sessions").contains(where: { $0.name == "cleanup_result" }) else {
            return nil
        }
        let row = try Row.fetchOne(
            db,
            sql: "SELECT cleanup_result, cleanup_at FROM terminal_sessions WHERE id = ? AND cleanup_result IS NOT NULL",
            arguments: [sessionID]
        )
        guard let row else { return nil }
        let json: String = row["cleanup_result"]
        var result: SessionCleanupPlan?
        do {
            result = try JSONDecoder().decode(SessionCleanupPlan.self, from: Data(json.utf8))
        } catch {
            NSLog("TerminalSessionQueries: session %lld cleanup_result does not decode: %@",
                  sessionID, String(describing: error))
        }
        return SessionCleanupRecord(result: result, at: row["cleanup_at"] ?? "")
    }

    /// Best-effort, unchecked: a session deleted meanwhile is not active,
    /// which is what it asks for.
    package static func touch(_ db: Database, id: Int64) throws {
        try db.execute(sql: "UPDATE terminal_sessions SET last_active_at = \(now) WHERE id = ?", arguments: [id])
    }

    package static func rename(_ db: Database, id: Int64, title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TerminalSessionQueryError.emptyTitle }
        try db.execute(
            sql: "UPDATE terminal_sessions SET title = ?, title_source = 'user' WHERE id = ?",
            arguments: [trimmed, id]
        )
        try db.requireUpdated(orThrow: TerminalSessionQueryError.notFound(id))
    }

    /// The per-conversation columns a conversation change clears, as Go's
    /// `SetTerminalClaudeSessionID` and `SetTerminalAgentSessionID` clear
    /// them: the turn order, the background agent count, the agent turns and
    /// the chat question. The working directory (`agent_cwd`) stays.
    private static let conversationResetColumns = """
        agent_turn_end = NULL, agent_tool_run = 0,
        agent_background = NULL, agent_background_at = NULL, chat_question = NULL, chat_question_at = NULL,
        agent_turns = NULL
        """

    /// "Start fresh": a new Claude session id under the same named row. The
    /// old conversation's columns go with it, the same write as Go's
    /// `SetTerminalClaudeSessionID` (the old transcript path included), so the
    /// row never shows the previous conversation's counts until the next run
    /// mark overwrites them (board #552).
    package static func replaceClaudeSessionID(_ db: Database, id: Int64, uuid: String) throws {
        try db.execute(
            sql: """
                UPDATE terminal_sessions SET claude_session_id = ?, agent_transcript_path = NULL,
                \(conversationResetColumns)
                WHERE id = ?
                """,
            arguments: [uuid, id]
        )
        try db.requireUpdated(orThrow: TerminalSessionQueryError.notFound(id))
    }

    /// "Start fresh" on a codex row: NULLs the stored session id and
    /// transcript path, so the next launch starts a new Codex session whose
    /// first SessionStart reports the new id, and clears the old
    /// conversation's columns as `replaceClaudeSessionID` does (Go clears the
    /// same ones when that first SessionStart stores the id). Any other kind is left
    /// untouched (a claude row keeps its id: see `replaceClaudeSessionID`).
    /// Throws `notFound` when the row is gone.
    package static func resetAgentSession(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: """
                UPDATE terminal_sessions SET claude_session_id = NULL, agent_transcript_path = NULL,
                \(conversationResetColumns)
                WHERE id = ? AND kind = 'codex'
                """,
            arguments: [id]
        )
        if db.changesCount == 0, try fetch(db, id: id) == nil {
            throw TerminalSessionQueryError.notFound(id)
        }
    }

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM terminal_sessions WHERE id = ?", arguments: [id])
    }
}
