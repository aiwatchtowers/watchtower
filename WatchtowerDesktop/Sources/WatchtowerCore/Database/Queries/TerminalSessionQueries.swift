import Foundation
import GRDB

package enum TerminalSessionQueryError: LocalizedError, Equatable {
    case emptyTitle
    case notFound(Int64)

    package var errorDescription: String? {
        switch self {
        case .emptyTitle: "A session needs a name."
        case let .notFound(id): "Terminal session \(id) no longer exists."
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

    package static func create(_ db: Database, _ new: NewSession) throws -> TerminalSession {
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

    package static func fetchForProject(_ db: Database, projectID: Int64) throws -> [TerminalSession] {
        try TerminalSession.fetchAll(
            db,
            sql: "SELECT * FROM terminal_sessions WHERE project_id = ? ORDER BY last_active_at DESC, id DESC",
            arguments: [projectID]
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

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM terminal_sessions WHERE id = ?", arguments: [id])
    }
}
