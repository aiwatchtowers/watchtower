import Foundation
import GRDB

/// The Chats panel's list (spec 2026-10-26 §5.2).
package enum ChatHistoryQueries {
    /// The main chat's conversations (standalone, not archived) with each
    /// row's second line and state, newest first — one read. `projectID`
    /// nil = all chats, else that project's only.
    package static func panelRows(_ db: Database, projectID: Int64?) throws -> [ChatPanelRow] {
        try ChatPanelRow.fetchAll(db, sql: """
            \(lastAnswerCTE(listed: "context_type IS NULL AND archived_at IS NULL AND (?1 IS NULL OR project_id = ?1)"))
            SELECT c.*,
                EXISTS (SELECT 1 FROM chat_attachments a WHERE a.conversation_id = c.id) AS has_attachments,
                p.name AS project_name,
                answer.created_at AS last_answer_at,
                substr(answer.text, 1, 200) AS last_answer_text,
                (SELECT COUNT(*) FROM agent_actions x
                 WHERE x.conversation_id = c.id AND x.status = 'pending') AS pending_approvals,
                (SELECT x.tool FROM agent_actions x
                 WHERE x.conversation_id = c.id AND x.status = 'pending'
                 ORDER BY x.created_at, x.id LIMIT 1) AS pending_tool
            FROM listed c
            LEFT JOIN chat_projects p ON p.id = c.project_id
            LEFT JOIN last_answer la ON la.conversation_id = c.id
            LEFT JOIN chat_messages answer ON answer.id = la.message_id
            ORDER BY c.updated_at DESC, c.id DESC
            """, arguments: [projectID])
    }

    /// `created_at` of one conversation's last complete answer on the
    /// active branch — what `panelRows` calls `lastAnswerAt`; nil before
    /// the first complete answer.
    package static func lastAnswerAt(_ db: Database, conversationID: Int64) throws -> Double? {
        try Double.fetchOne(db, sql: """
            \(lastAnswerCTE(listed: "id = ?1"))
            SELECT m.created_at FROM last_answer la JOIN chat_messages m ON m.id = la.message_id
            """, arguments: [conversationID])
    }

    /// `listed` = the conversations matching `listed` (a fixed predicate,
    /// never caller text); `last_answer(conversation_id, message_id)` = each
    /// one's last complete assistant message on the visible thread: the
    /// path from `active_leaf_message_id` up through `parent_id`
    /// (`ChatTreeQueries`), so an answer on another branch never counts. A
    /// chat without a leaf has no branches and reads every message, as
    /// `ChatTreeQueries` does. Message ids grow from parent to child, so the
    /// newest answer on the path is its largest id.
    package static func lastAnswerCTE(listed predicate: String) -> String {
        """
        WITH RECURSIVE listed AS (
            SELECT * FROM chat_conversations WHERE \(predicate)
        ),
        path(conversation_id, message_id) AS (
            SELECT id, active_leaf_message_id FROM listed WHERE active_leaf_message_id IS NOT NULL
            UNION
            SELECT path.conversation_id, m.parent_id FROM path
            JOIN chat_messages m ON m.id = path.message_id
            WHERE m.parent_id IS NOT NULL
        ),
        branch_answer(conversation_id, message_id) AS (
            SELECT path.conversation_id, MAX(m.id) FROM path
            JOIN chat_messages m ON m.id = path.message_id AND m.conversation_id = path.conversation_id
            WHERE m.role = 'assistant' AND m.status = 'complete'
            GROUP BY path.conversation_id
        ),
        last_answer(conversation_id, message_id) AS (
            SELECT c.id, CASE
                WHEN c.active_leaf_message_id IS NULL THEN (
                    SELECT MAX(m.id) FROM chat_messages m
                    WHERE m.conversation_id = c.id AND m.role = 'assistant' AND m.status = 'complete')
                ELSE (SELECT b.message_id FROM branch_answer b WHERE b.conversation_id = c.id)
            END
            FROM listed c
        )
        """
    }
}
