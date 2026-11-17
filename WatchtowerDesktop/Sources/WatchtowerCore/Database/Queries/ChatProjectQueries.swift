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

    package static func files(_ db: Database, projectID: Int64) throws -> [ChatAttachment] {
        try ChatAttachment.fetchAll(
            db,
            sql: "SELECT * FROM chat_attachments WHERE project_id = ? ORDER BY created_at, id",
            arguments: [projectID]
        )
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

}
