import Foundation
import GRDB

package enum ChatConversationQueries {
    package static func fetchAll(_ db: Database) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT * FROM chat_conversations ORDER BY updated_at DESC
        """)
    }

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

    package static func search(_ db: Database, query: String) throws -> [ChatConversation] {
        let pattern = "%\(query)%"
        return try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_conversations WHERE context_type IS NULL AND title LIKE ? ORDER BY updated_at DESC
                """,
            arguments: [pattern]
        )
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

    /// Owner rename — `title_source='user'` keeps `chat title` and the
    /// prefix title from ever overwriting it.
    package static func rename(_ db: Database, id: Int64, title: String) throws {
        try db.execute(sql: """
            UPDATE chat_conversations SET title = ?, title_source = 'user', updated_at = ? WHERE id = ?
        """, arguments: [title, Date().timeIntervalSince1970, id])
        try db.requireUpdated("chat", id: id)
    }

    /// First-message title (80 chars), only while nothing better exists.
    package static func setPrefixTitle(_ db: Database, id: Int64, text: String) throws {
        try db.execute(sql: """
            UPDATE chat_conversations SET title = ? WHERE id = ? AND title_source = 'prefix' AND title = ''
        """, arguments: [String(text.prefix(80)), id])
    }

    /// True exactly when the conversation still has its prefix title and has
    /// just finished its first assistant reply (spec §4.4).
    package static func needsAITitle(_ db: Database, id: Int64) throws -> Bool {
        let completed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM chat_messages m
            JOIN chat_conversations c ON c.id = m.conversation_id
            WHERE c.id = ? AND c.title_source = 'prefix' AND m.role = 'assistant' AND m.status = 'complete'
            """, arguments: [id]) ?? 0
        return completed == 1
    }

    package static func pin(_ db: Database, id: Int64, pinned: Bool) throws {
        try db.execute(sql: "UPDATE chat_conversations SET pinned = ? WHERE id = ?", arguments: [pinned ? 1 : 0, id])
        try db.requireUpdated("chat", id: id)
    }

    package static func archive(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET archived_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
        try db.requireUpdated("chat", id: id)
    }

    /// Moves a conversation into (or out of) a project. An actual move also
    /// clears the stored provider session: a `--resume`d Claude session keeps
    /// the prompt it was started with, so it would never see the new
    /// project's block or files — the next turn starts fresh and replays.
    /// Moving to the project it is already in changes nothing — so zero rows
    /// is a normal outcome here and the write stays unchecked.
    package static func setProject(_ db: Database, id: Int64, projectID: Int64?) throws {
        try db.execute(
            sql: """
                UPDATE chat_conversations SET project_id = ?, session_id = NULL
                WHERE id = ? AND project_id IS NOT ?
                """,
            arguments: [projectID, id, projectID]
        )
    }

    package static func setProviderModel(_ db: Database, id: Int64, provider: String, model: String?) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET provider = ?, model = ? WHERE id = ?",
            arguments: [provider, model, id]
        )
    }

    package static func updateSessionID(_ db: Database, id: Int64, sessionID: String?) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET session_id = ?, updated_at = ? WHERE id = ?
        """, arguments: [sessionID, now, id])
    }

    /// `updateSessionID` guarded by the project the session was spawned for:
    /// a no-op once the conversation moved to another project (or out).
    package static func updateSessionID(_ db: Database, id: Int64, sessionID: String, projectID: Int64?) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            UPDATE chat_conversations SET session_id = ?, updated_at = ? WHERE id = ? AND project_id IS ?
        """, arguments: [sessionID, now, id, projectID])
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

    /// An "untouched" main chat: standalone, outside any project, not
    /// archived, never pinned or renamed by the owner, with no message and no
    /// attachment — what the Chat landing makes on its first keystroke and
    /// discards when it is left unused. Callers only ever pass the landing's
    /// own draft id: an empty chat of any other origin (moved out of a
    /// project, or left by a deleted one) is never theirs to delete.
    private static let untouchedPredicate = """
        c.context_type IS NULL AND c.project_id IS NULL AND c.archived_at IS NULL
        AND c.pinned = 0 AND c.title_source <> 'user'
        AND NOT EXISTS (SELECT 1 FROM chat_messages m WHERE m.conversation_id = c.id)
        AND NOT EXISTS (SELECT 1 FROM chat_attachments a WHERE a.conversation_id = c.id)
        """

    /// The landing's draft while it is still untouched, for reuse. `createdAt`
    /// must match too: the draft is persisted across launches, and a reset
    /// database at the same path can reissue the id to an unrelated chat.
    package static func fetchUntouched(_ db: Database, id: Int64, createdAt: Double) throws -> ChatConversation? {
        try ChatConversation.fetchOne(db, sql: """
            SELECT c.* FROM chat_conversations c WHERE c.id = ? AND c.created_at = ? AND \(untouchedPredicate)
            """, arguments: [id, createdAt])
    }

    /// Deletes the landing's draft only while it is still untouched (and is
    /// still the same row: `createdAt` matches); true when it was deleted.
    @discardableResult
    package static func deleteIfUntouched(_ db: Database, id: Int64, createdAt: Double) throws -> Bool {
        try db.execute(sql: """
            DELETE FROM chat_conversations WHERE id IN (
                SELECT c.id FROM chat_conversations c WHERE c.id = ? AND c.created_at = ? AND \(untouchedPredicate))
            """, arguments: [id, createdAt])
        return db.changesCount > 0
    }

    package static func fetchByID(_ db: Database, id: Int64) throws -> ChatConversation? {
        try ChatConversation.fetchOne(db, sql: "SELECT * FROM chat_conversations WHERE id = ?", arguments: [id])
    }
}
