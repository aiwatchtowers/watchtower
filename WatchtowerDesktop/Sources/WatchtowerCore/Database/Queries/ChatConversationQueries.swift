import Foundation
import GRDB

package enum ChatConversationQueries {

    /// The main chat's list; `has_attachments` lets a message-less chat
    /// that holds unsent files stay visible in the history.
    package static func fetchStandalone(_ db: Database) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT c.*, EXISTS (SELECT 1 FROM chat_attachments a WHERE a.conversation_id = c.id) AS has_attachments
            FROM chat_conversations c
            WHERE c.context_type IS NULL AND c.archived_at IS NULL
            ORDER BY c.updated_at DESC
        """)
    }

    @discardableResult
    package static func create(
        _ db: Database, title: String = "", contextType: String? = nil, contextID: String? = nil, projectID: Int64? = nil
    ) throws -> ChatConversation {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, context_type, context_id, project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [title, contextType, contextID, projectID, now, now])
        let rowID = db.lastInsertedRowID
        guard let conversation = try fetchByID(db, id: rowID) else {
            throw DatabaseError(message: "Failed to fetch newly created chat conversation")
        }
        return conversation
    }

    package static func fetchByContext(_ db: Database, type: String, id: String) throws -> ChatConversation? {
        try ChatConversation.fetchOne(
            db,
            sql: """
                SELECT * FROM chat_conversations WHERE context_type = ? AND context_id = ? ORDER BY updated_at DESC LIMIT 1
                """,
            arguments: [type, id]
        )
    }

    /// All conversations for one context, oldest first — the tab order on the
    /// target assistant. `id` breaks ties so two rows created inside the same
    /// `Date()` tick keep a stable order.
    package static func fetchAllByContext(_ db: Database, type: String, id: String) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_conversations
                WHERE context_type = ? AND context_id = ?
                ORDER BY created_at ASC, id ASC
                """,
            arguments: [type, id]
        )
    }

    /// When this context last had a real chat TURN, or nil when it has had none.
    ///
    /// Deliberately measured over `chat_messages`, not over the conversations'
    /// own `updated_at`: a row's stamp moves when the tab is merely created or
    /// renamed, so a `MAX(updated_at)` would report "activity" for an empty tab
    /// the operator just opened. It also lags a real turn — only the assistant's
    /// reply calls `touch`, so a user turn whose reply failed would report none.
    /// Every persisted message (user, assistant and the "Action applied: …"
    /// system lines) counts, and only those.
    ///
    /// `created_at` is a REAL unix timestamp in these Swift-owned tables, so the
    /// raw MAX is seconds since 1970. `chat_messages` is created by the Desktop
    /// module alongside `chat_conversations`; a caller running before either
    /// exists gets the thrown "no such table", which reads as "no activity".
    package static func latestTurnActivity(_ db: Database, type: String, id: String) throws -> Date? {
        let newest = try Double.fetchOne(
            db,
            sql: """
                SELECT MAX(m.created_at) FROM chat_messages m
                JOIN chat_conversations c ON c.id = m.conversation_id
                WHERE c.context_type = ? AND c.context_id = ?
                """,
            arguments: [type, id]
        )
        guard let newest else { return nil }
        return Date(timeIntervalSince1970: newest)
    }

    /// Best-effort, unchecked: an automatic (first-turn / AI) title, not an
    /// owner edit — a chat deleted meanwhile needs no title.
    package static func updateTitle(_ db: Database, id: Int64, title: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET title = ?, updated_at = ? WHERE id = ?
        """, arguments: [title, now, id])
    }

    package static func setProviderModel(_ db: Database, id: Int64, provider: String, model: String?) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET provider = ?, model = ? WHERE id = ?",
            arguments: [provider, model, id]
        )
    }

    package static func touch(_ db: Database, id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET updated_at = ? WHERE id = ?
        """, arguments: [now, id])
    }

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [id])
    }

    /// An "untouched" main chat: standalone, in the landing's project (or
    /// outside any, `project_id IS ?`), not archived, never pinned or renamed
    /// by the owner, with no message and no attachment — what the Chat
    /// landing makes on its first keystroke and discards when it is left
    /// unused. Callers only ever pass the landing's own draft id and project:
    /// an empty chat of any other origin (moved out of a project, or left by
    /// a deleted one) is never theirs to delete.
    package static let untouchedPredicate = """
        c.context_type IS NULL AND c.project_id IS ? AND c.archived_at IS NULL
        AND c.pinned = 0 AND c.title_source <> 'user'
        AND NOT EXISTS (SELECT 1 FROM chat_messages m WHERE m.conversation_id = c.id)
        AND NOT EXISTS (SELECT 1 FROM chat_attachments a WHERE a.conversation_id = c.id)
        """

    /// Which of `ids` are still conversations (a chat mention's "Chat
    /// deleted" check).
    package static func existingIDs(_ db: Database, ids: [Int64]) throws -> Set<Int64> {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: unique.count).joined(separator: ",")
        return Set(try Int64.fetchAll(db, sql: "SELECT id FROM chat_conversations WHERE id IN (\(marks))",
                                      arguments: StatementArguments(unique)))
    }

    package static func fetchByID(_ db: Database, id: Int64) throws -> ChatConversation? {
        try ChatConversation.fetchOne(db, sql: "SELECT * FROM chat_conversations WHERE id = ?", arguments: [id])
    }
}
