import Foundation
import GRDB

/// Chat projects (spec §6.1). Swift is the only writer of `chat_projects`,
/// `chat_project_sources` and project-owned `chat_attachments` rows; Go only
/// reads them (`db.GetChatProjectContext`) when `ai session --project-id`
/// builds the prompt and the first-turn attachments.
package enum ChatProjectQueries {
    package static let defaultName = "New project"

    package static func fetchActive(_ db: Database) throws -> [ChatProject] {
        try ChatProject.fetchAll(db, sql: """
            SELECT * FROM chat_projects WHERE archived_at IS NULL
            ORDER BY name COLLATE NOCASE, id
            """)
    }

    package static func fetchByID(_ db: Database, id: Int64) throws -> ChatProject? {
        try ChatProject.fetchOne(db, sql: "SELECT * FROM chat_projects WHERE id = ?", arguments: [id])
    }

    @discardableResult
    package static func create(_ db: Database, name: String) throws -> ChatProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
                INSERT INTO chat_projects (name, instructions, created_at, updated_at)
                VALUES (?, '', ?, ?)
                """,
            arguments: [trimmed.isEmpty ? defaultName : trimmed, now, now]
        )
        guard let project = try fetchByID(db, id: db.lastInsertedRowID) else {
            throw DatabaseError(message: "Failed to fetch newly created chat project")
        }
        return project
    }

    /// A blank name is ignored rather than stored: a project row always has a
    /// name to show in the sidebar.
    package static func rename(_ db: Database, id: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.execute(
            sql: "UPDATE chat_projects SET name = ?, updated_at = ? WHERE id = ?",
            arguments: [trimmed, Date().timeIntervalSince1970, id]
        )
        try db.requireUpdated("chat project", id: id)
    }

    package static func updateInstructions(_ db: Database, id: Int64, instructions: String) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET instructions = ?, updated_at = ? WHERE id = ?",
            arguments: [instructions, Date().timeIntervalSince1970, id]
        )
        try db.requireUpdated("chat project", id: id)
    }

    package static func archive(_ db: Database, id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "UPDATE chat_projects SET archived_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, id]
        )
        try db.requireUpdated("chat project", id: id)
    }

    /// Deletes the project. Its chats survive detached (`ON DELETE SET NULL`),
    /// its sources and file rows go by cascade. Returns the file paths so the
    /// caller removes them from disk AFTER the transaction commits.
    package static func delete(_ db: Database, id: Int64) throws -> [String] {
        let paths = try String.fetchAll(
            db, sql: "SELECT DISTINCT path FROM chat_attachments WHERE project_id = ? ORDER BY path",
            arguments: [id]
        )
        try db.execute(sql: "DELETE FROM chat_projects WHERE id = ?", arguments: [id])
        return paths
    }

    package static func sources(_ db: Database, projectID: Int64) throws -> [ChatProjectSource] {
        try ChatProjectSource.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_project_sources WHERE project_id = ?
                ORDER BY kind, label COLLATE NOCASE, id
                """,
            arguments: [projectID]
        )
    }

    /// Returns false (and writes nothing) when the same (kind, ref) is already
    /// pinned to the project — the table's `UNIQUE(project_id, kind, ref)`.
    @discardableResult
    package static func addSource(
        _ db: Database, projectID: Int64, kind: ChatProjectSource.Kind, ref: String, label: String
    ) throws -> Bool {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO chat_project_sources (project_id, kind, ref, label)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [projectID, kind.rawValue, ref, label]
        )
        guard db.changesCount > 0 else { return false }
        try touch(db, id: projectID)
        return true
    }

    package static func removeSource(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_project_sources WHERE id = ?", arguments: [id])
    }

    package static func files(_ db: Database, projectID: Int64) throws -> [ChatAttachment] {
        try ChatAttachment.fetchAll(
            db,
            sql: "SELECT * FROM chat_attachments WHERE project_id = ? ORDER BY created_at, id",
            arguments: [projectID]
        )
    }

    /// Deletes one project file row and returns its path for post-commit disk
    /// removal. Nil when no project file has that id (a conversation's
    /// attachment is never touched here) or when another row still points at
    /// the same stored file (`ChatAttachmentStore` reuses a file by sha256).
    package static func removeFile(_ db: Database, id: Int64) throws -> String? {
        guard let path = try String.fetchOne(
            db, sql: "SELECT path FROM chat_attachments WHERE id = ? AND project_id IS NOT NULL",
            arguments: [id]
        ) else { return nil }
        try ChatAttachmentQueries.delete(db, id: id)
        return try ChatAttachmentQueries.referenceCount(db, path: path) == 0 ? path : nil
    }

    package static func conversations(_ db: Database, projectID: Int64) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_conversations
                WHERE project_id = ? AND archived_at IS NULL
                ORDER BY updated_at DESC, id DESC
                """,
            arguments: [projectID]
        )
    }

    private static func touch(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET updated_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }
}
