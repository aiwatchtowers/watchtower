import Foundation
import GRDB

/// Chat projects (spec §6.1). Swift is the only writer of `chat_projects`,
/// `chat_project_sources` and project-owned `chat_attachments` rows; Go only
/// reads them (`db.GetChatProjectContext`) when `ai session --project-id`
/// builds the prompt and the first-turn attachments.
///
/// Every write that changes what that prompt or those attachments hold
/// (instructions, sources, files, delete — a rename, cosmetic, does not)
/// also drops the project's stored
/// Claude sessions in the same transaction (`dropSessions`), as
/// `ChatConversationQueries.setProject` does on a move: a `--resume`d
/// session keeps the prompt it was started with, so it would never see the
/// edit. The caller retires the warm processes (`ChatSessionPool`).
package enum ChatProjectQueries {
    package static let defaultName = "New project"

    package static func fetchActive(_ db: Database) throws -> [ChatProject] {
        try ChatProject.fetchAll(db, sql: """
            SELECT * FROM chat_projects WHERE archived_at IS NULL
            ORDER BY name COLLATE NOCASE, id
            """)
    }

    /// One row per active project for the Chats project switcher: latest
    /// standalone chat `updated_at` (else the project's own), the chats with
    /// an unread answer and the pending approvals — the same definitions as
    /// `ChatHistoryQueries.panelRows` (`ChatPanelRow.isUnread`). Answering
    /// counts come from the pool at render time. Unsorted.
    package static func switcherSummaries(
        _ db: Database,
        hiding hidden: Set<Int64> = []
    ) throws -> [ChatProjectSwitcherPresentation.Summary] {
        // The chats waiting in the panel's Undo window count for nothing
        // (spec 2026-10-26 §5.3); ids are integers, so inlined.
        let hiding = hidden.isEmpty ? "" : " AND id NOT IN (\(hidden.sorted().map(String.init).joined(separator: ",")))"
        let listed = "context_type IS NULL AND archived_at IS NULL AND project_id IS NOT NULL" + hiding
        let rows = try Row.fetchAll(db, sql: """
            \(ChatHistoryQueries.lastAnswerCTE(listed: listed))
            SELECT p.id, p.name,
                COALESCE((SELECT MAX(c.updated_at) FROM listed c WHERE c.project_id = p.id), p.updated_at) AS last_activity,
                (SELECT COUNT(*) FROM listed c
                 JOIN last_answer la ON la.conversation_id = c.id
                 JOIN chat_messages answer ON answer.id = la.message_id
                 WHERE c.project_id = p.id AND (c.read_at IS NULL OR answer.created_at > c.read_at)) AS unread,
                (SELECT COUNT(*) FROM agent_actions x JOIN listed c ON c.id = x.conversation_id
                 WHERE c.project_id = p.id AND x.status = 'pending') AS waiting
            FROM chat_projects p WHERE p.archived_at IS NULL
            """)
        return rows.map {
            ChatProjectSwitcherPresentation.Summary(
                id: $0["id"], name: $0["name"],
                lastActivity: Date(timeIntervalSince1970: $0["last_activity"]),
                unreadCount: $0["unread"], waitingCount: $0["waiting"]
            )
        }
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
        try dropSessions(db, projectID: id)
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
        // Before the delete: its chats are detached by ON DELETE SET NULL.
        try dropSessions(db, projectID: id)
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
        try dropSessions(db, projectID: projectID)
        return true
    }

    /// Returns false (and writes nothing) when no source has that id.
    @discardableResult
    package static func removeSource(_ db: Database, id: Int64) throws -> Bool {
        guard let projectID = try Int64.fetchOne(
            db, sql: "SELECT project_id FROM chat_project_sources WHERE id = ?", arguments: [id]
        ) else { return false }
        try db.execute(sql: "DELETE FROM chat_project_sources WHERE id = ?", arguments: [id])
        try dropSessions(db, projectID: projectID)
        return true
    }

    package static func files(_ db: Database, projectID: Int64) throws -> [ChatAttachment] {
        try ChatAttachment.fetchAll(
            db,
            sql: "SELECT * FROM chat_attachments WHERE project_id = ? ORDER BY created_at, id",
            arguments: [projectID]
        )
    }

    /// Deletes one project file row. `removed` is false when no project file
    /// has that id (a conversation's attachment is never touched here).
    /// `orphanPath` is the stored file to remove from disk post-commit — nil
    /// when another row still points at it (`ChatAttachmentStore` reuses a
    /// file by sha256).
    package static func removeFile(_ db: Database, id: Int64) throws -> (removed: Bool, orphanPath: String?) {
        guard let row = try Row.fetchOne(
            db, sql: "SELECT path, project_id FROM chat_attachments WHERE id = ? AND project_id IS NOT NULL",
            arguments: [id]
        ) else { return (false, nil) }
        let path: String = row["path"]
        try ChatAttachmentQueries.delete(db, id: id)
        try dropSessions(db, projectID: row["project_id"])
        return (true, try ChatAttachmentQueries.referenceCount(db, path: path) == 0 ? path : nil)
    }

    /// The project page's chats: unarchived, with a message or a file — the
    /// Chats panel's rule (`ChatHistoryViewModel.sections`), so the page's
    /// own unsent draft and an untouched chat are not listed.
    package static func conversations(_ db: Database, projectID: Int64) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT c.* FROM chat_conversations c
                WHERE c.project_id = ? AND c.archived_at IS NULL
                  AND (c.active_leaf_message_id IS NOT NULL
                       OR EXISTS (SELECT 1 FROM chat_attachments a WHERE a.conversation_id = c.id))
                ORDER BY c.updated_at DESC, c.id DESC
                """,
            arguments: [projectID]
        )
    }

    /// Forgets the stored Claude session of every chat in the project, so
    /// each one's next turn starts fresh with the current prompt and replays.
    package static func dropSessions(_ db: Database, projectID: Int64) throws {
        try db.execute(sql: "UPDATE chat_conversations SET session_id = NULL WHERE project_id = ?",
                       arguments: [projectID])
    }

    private static func touch(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET updated_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }
}
