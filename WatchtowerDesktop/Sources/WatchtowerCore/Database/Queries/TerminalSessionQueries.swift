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

        package init(
            projectID: Int64?,
            kind: TerminalSession.Kind,
            title: String,
            targetID: Int64? = nil,
            folderPath: String,
            claudeSessionID: String? = nil
        ) {
            self.projectID = projectID
            self.kind = kind
            self.title = title
            self.targetID = targetID
            self.folderPath = folderPath
            self.claudeSessionID = claudeSessionID
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
                    (project_id, kind, title, target_id, folder_path, claude_session_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [new.projectID, new.kind.rawValue, new.title, new.targetID, new.folderPath, new.claudeSessionID]
        )
        let id = db.lastInsertedRowID
        guard let row = try fetch(db, id: id) else { throw TerminalSessionQueryError.notFound(id) }
        return row
    }

    package static func fetch(_ db: Database, id: Int64) throws -> TerminalSession? {
        try TerminalSession.fetchOne(db, sql: "SELECT * FROM terminal_sessions WHERE id = ?", arguments: [id])
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
    /// recorded Chat question and its stamp, the open-ask count and the
    /// oldest open ask, with the workbench name a notice names. Read-only:
    /// Go writes these columns.
    package static func fetchAgentStates(_ db: Database, liveIDs: [Int64]) throws -> [SessionAgentStateRow] {
        let marks = liveIDs.isEmpty ? "NULL" : databaseQuestionMarks(count: liveIDs.count)
        return try SessionAgentStateRow.fetchAll(
            db,
            sql: """
                SELECT s.id, s.project_id, s.title, s.agent_state, s.agent_state_at, p.name AS workbench_name,
                       s.finished_at, s.finish_summary, s.agent_failed_at, s.agent_error,
                       s.agent_background, s.agent_background_at, s.chat_question, s.chat_question_at,
                       (SELECT COUNT(*) FROM owner_asks a WHERE a.session_id = s.id AND a.status = 'open') AS open_asks,
                       (SELECT MIN(a.id) FROM owner_asks a WHERE a.session_id = s.id AND a.status = 'open')
                           AS oldest_open_ask_id
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
    /// GRDB caches it per connection until the schema version changes, so a
    /// database migrated while the app runs gets its cwds on the next read.
    package static func fetchAgentCwds(_ db: Database, projectID: Int64) throws -> [Int64: SessionAgentCwd] {
        guard try db.columns(in: "terminal_sessions").contains(where: { $0.name == "agent_cwd_at" }) else { return [:] }
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

    /// "Start fresh": a new Claude session id under the same named row.
    package static func replaceClaudeSessionID(_ db: Database, id: Int64, uuid: String) throws {
        try db.execute(
            sql: "UPDATE terminal_sessions SET claude_session_id = ? WHERE id = ?",
            arguments: [uuid, id]
        )
        try db.requireUpdated(orThrow: TerminalSessionQueryError.notFound(id))
    }

    /// "Start fresh" on a codex row: NULLs the stored session id and
    /// transcript path, so the next launch starts a new Codex session whose
    /// first SessionStart reports the new id. Any other kind is left
    /// untouched (a claude row keeps its id: see `replaceClaudeSessionID`).
    /// Throws `notFound` when the row is gone.
    package static func resetAgentSession(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: """
                UPDATE terminal_sessions SET claude_session_id = NULL, agent_transcript_path = NULL
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
