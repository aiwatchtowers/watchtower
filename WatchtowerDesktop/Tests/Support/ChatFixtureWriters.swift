import Foundation
import GRDB
import WatchtowerChatText
import WatchtowerCore

// The main chat's former Swift writers (and the reads only they used), kept for the tests that seed chat rows: the
// app writes none of these since the chat moved onto the engine (unified chat T8, D3 — every write of the main chat
// is an engine operation). Same names, so the tests' fixtures read as before.

extension ChatConversationQueries {
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

    package static func fetchAll(_ db: Database) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT * FROM chat_conversations ORDER BY updated_at DESC
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
    /// Explicit complete choice. Automatic also explicitly removes the model pin.
    package static func setRouting(_ db: Database, id: Int64, automatic: Bool, provider: String, model: String?) throws {
        guard automatic || ManagedPolicy.knownProviders.contains(provider) else {
            throw DatabaseError(message: "Invalid chat provider")
        }
        try db.execute(sql: """
            UPDATE chat_conversations SET routing_mode = ?, provider = ?, model = ?,
                actual_provider = '', actual_model = '', routing_reason = '' WHERE id = ?
            """, arguments: [
                automatic ? "preferred_reserve" : "pinned", automatic ? nil : provider, automatic ? nil : model, id
            ])
        try db.requireUpdated("chat", id: id)
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
    /// The landing's draft while it is still untouched, for reuse. `createdAt`
    /// must match too: the draft is persisted across launches, and a reset
    /// database at the same path can reissue the id to an unrelated chat.
    package static func fetchUntouched(
        _ db: Database, id: Int64, createdAt: Double, projectID: Int64? = nil
    ) throws -> ChatConversation? {
        try ChatConversation.fetchOne(db, sql: """
            SELECT c.* FROM chat_conversations c WHERE c.id = ? AND c.created_at = ? AND \(untouchedPredicate)
            """, arguments: [id, createdAt, projectID])
    }
    /// Deletes the landing's draft only while it is still untouched (and is
    /// still the same row: `createdAt` matches); true when it was deleted.
    @discardableResult
    package static func deleteIfUntouched(
        _ db: Database, id: Int64, createdAt: Double, projectID: Int64? = nil
    ) throws -> Bool {
        try db.execute(sql: """
            DELETE FROM chat_conversations WHERE id IN (
                SELECT c.id FROM chat_conversations c WHERE c.id = ? AND c.created_at = ? AND \(untouchedPredicate))
            """, arguments: [id, createdAt, projectID])
        return db.changesCount > 0
    }
}

extension ChatProjectQueries {
    package static func fetchActive(_ db: Database) throws -> [ChatProject] {
        try ChatProject.fetchAll(db, sql: """
            SELECT * FROM chat_projects WHERE archived_at IS NULL
            ORDER BY name COLLATE NOCASE, id
            """)
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
    /// Forgets the stored Claude session of every chat in the project, so
    /// each one's next turn starts fresh with the current prompt and replays.
    package static func dropSessions(_ db: Database, projectID: Int64) throws {
        try db.execute(sql: "UPDATE chat_conversations SET session_id = NULL WHERE project_id = ?",
                       arguments: [projectID])
    }
    static func touch(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET updated_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }
}

extension ChatTreeQueries {
    struct NewMessage {
        let conversationID: Int64
        let parentID: Int64?
        let role: String
        let text: String
        let turnID: String
        let status: String
        let provider: String?
        let model: String?
    }

    package static func activePath(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        let all = try allMessages(db, conversationID: conversationID)
        return try resolvePath(db, conversationID: conversationID, all: all).path
    }
    package static func siblings(_ db: Database, messageID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(db, sql: """
            SELECT * FROM chat_messages
            WHERE conversation_id = (SELECT conversation_id FROM chat_messages WHERE id = ?)
              AND parent_id IS (SELECT parent_id FROM chat_messages WHERE id = ?)
            ORDER BY id
            """, arguments: [messageID, messageID])
    }
    /// The most recently written message of any branch — what a resumed
    /// provider session last saw, when that turn ran on the same provider.
    package static func newestMessage(_ db: Database, conversationID: Int64) throws -> ChatMessageRecord? {
        try ChatMessageRecord.fetchOne(
            db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id DESC LIMIT 1",
            arguments: [conversationID]
        )
    }
    @discardableResult
    package static func insertUser(
        _ db: Database, conversationID: Int64, parentID: Int64?, text: String, turnID: String
    ) throws -> ChatMessageRecord {
        try insert(db, NewMessage(conversationID: conversationID, parentID: parentID, role: "user", text: text,
                                  turnID: turnID, status: "complete", provider: nil, model: nil))
    }
    /// The assistant row is created empty and `partial` BEFORE the turn is
    /// sent, so a crash at any point leaves a row the owner can Continue.
    @discardableResult
    package static func insertAssistant(
        _ db: Database, conversationID: Int64, parentID: Int64?, turnID: String, provider: String, model: String
    ) throws -> ChatMessageRecord {
        try insert(db, NewMessage(conversationID: conversationID, parentID: parentID, role: "assistant", text: "",
                                  turnID: turnID, status: "partial", provider: provider,
                                  model: model.isEmpty ? nil : model))
    }
    /// `errorMessage` is the session's own text for a failed turn, shown
    /// under the generic phrase of `errorCode`.
    package static func updateAssistant(
        _ db: Database,
        id: Int64,
        text: String,
        status: String,
        tokensIn: Int?,
        tokensOut: Int?,
        errorCode: String?,
        errorMessage: String?
    ) throws {
        try db.execute(sql: """
            UPDATE chat_messages SET text = ?, status = ?, tokens_in = ?, tokens_out = ?, error_code = ?, error_message = ?
            WHERE id = ?
            """, arguments: [text, status, tokensIn, tokensOut, errorCode, errorMessage, id])
    }
    package static func setModel(_ db: Database, messageID: Int64, model: String) throws {
        try db.execute(sql: "UPDATE chat_messages SET model = ? WHERE id = ?", arguments: [model, messageID])
    }
    package static func setActiveLeaf(_ db: Database, conversationID: Int64, messageID: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
            arguments: [messageID, conversationID]
        )
    }
    /// Show `siblingID`'s branch: the leaf moves to the newest leaf under it.
    package static func selectSibling(_ db: Database, conversationID: Int64, siblingID: Int64) throws {
        let tree = ChatTree(nodes: try allMessages(db, conversationID: conversationID).map(node))
        try setActiveLeaf(db, conversationID: conversationID, messageID: tree.newestLeaf(under: siblingID))
    }
    static func insert(_ db: Database, _ m: NewMessage) throws -> ChatMessageRecord {
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status, provider, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [m.conversationID, m.parentID, m.role, m.text, Date().timeIntervalSince1970,
                             m.turnID, m.status, m.provider, m.model])
        let id = db.lastInsertedRowID
        try setActiveLeaf(db, conversationID: m.conversationID, messageID: id)
        try ChatConversationQueries.touch(db, id: m.conversationID)
        guard let row = try ChatMessageRecord.fetchOne(db, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat message \(id) vanished after insert")
        }
        return row
    }
}

extension ChatArtifactQueries {
    /// Stores one version. Non-edit save from the message that produced the
    /// key's current latest (non-edited) version overwrites it in place —
    /// re-persisting a turn is idempotent and the last same-key block of one
    /// message wins. Everything else inserts `max(version) + 1`.
    @discardableResult
    package static func saveVersion(
        _ db: Database, conversationID: Int64, messageID: Int64, draft: ArtifactDraft, edited: Bool
    ) throws -> ChatArtifact {
        let metaJSON = try encodeMeta(draft.meta)
        if !edited, let latest = try latest(db, conversationID: conversationID, key: draft.key),
           latest.messageID == messageID, !latest.edited {
            // Unchecked: `latest` was read in this same write transaction.
            try db.execute(sql: """
                UPDATE chat_artifacts SET kind = ?, title = ?, content = ?, meta_json = ? WHERE id = ?
                """, arguments: [draft.kind, draft.title, draft.content, metaJSON, latest.id])
            return try fetch(db, id: latest.id)
        }
        let maxVersion = try Int.fetchOne(db, sql: """
            SELECT MAX(version) FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ?
            """, arguments: [conversationID, draft.key]) ?? 0
        try db.execute(sql: """
            INSERT INTO chat_artifacts
                (conversation_id, message_id, artifact_key, version, kind, title, content, meta_json, edited, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, messageID, draft.key, maxVersion + 1, draft.kind, draft.title,
                             draft.content, metaJSON, edited ? 1 : 0, Date().timeIntervalSince1970])
        return try fetch(db, id: db.lastInsertedRowID)
    }
    package static func latest(_ db: Database, conversationID: Int64, key: String) throws -> ChatArtifact? {
        try ChatArtifact.fetchOne(db, sql: """
            SELECT * FROM chat_artifacts WHERE conversation_id = ? AND artifact_key = ? ORDER BY version DESC LIMIT 1
            """, arguments: [conversationID, key])
    }
    /// Parses a finished assistant message (`final: true`) and stores every artifact.
    @discardableResult
    package static func persistArtifacts(
        _ db: Database, conversationID: Int64, messageID: Int64, text: String
    ) throws -> [ChatArtifact] {
        try ArtifactParser.parse(text, final: true).artifacts.map {
            try saveVersion(db, conversationID: conversationID, messageID: messageID, draft: $0, edited: false)
        }
    }
    /// message id → (artifact key → the non-edited version that message produced), for card badges.
    package static func versionsByMessage(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [String: Int]] {
        guard !messageIDs.isEmpty else { return [:] }
        let rows = try Row.fetchAll(db, sql: """
            SELECT message_id, artifact_key, MAX(version) AS version FROM chat_artifacts
            WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count))) AND edited = 0
            GROUP BY message_id, artifact_key
            """, arguments: StatementArguments(messageIDs))
        var out: [Int64: [String: Int]] = [:]
        for row in rows {
            let messageID: Int64 = row["message_id"]
            let key: String = row["artifact_key"]
            out[messageID, default: [:]][key] = row["version"]
        }
        return out
    }
    /// Pins `version` of an artifact as knowledge (**Keep in Knowledge**, and
    /// **Update in Knowledge** for a newer version: one kept version per key).
    /// Refused with `ChatArtifactKeepError.liveSlack` in a conversation that used
    /// the Live Slack connector (LIVE-01): its text never becomes knowledge.
    package static func keep(_ db: Database, conversationID: Int64, artifactKey: String, version: Int) throws {
        if try LiveSlackMark.isMarked(db, conversationID: conversationID) {
            throw ChatArtifactKeepError.liveSlack
        }
        try db.execute(sql: """
            INSERT INTO chat_knowledge_artifacts (conversation_id, artifact_key, version, kept_at)
            VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
            ON CONFLICT (conversation_id, artifact_key) DO UPDATE SET
                version = excluded.version, kept_at = excluded.kept_at
            """, arguments: [conversationID, artifactKey, version])
    }
    /// **Remove from Knowledge**; a key that is not kept is a no-op.
    package static func unkeep(_ db: Database, conversationID: Int64, artifactKey: String) throws {
        try db.execute(sql: """
            DELETE FROM chat_knowledge_artifacts WHERE conversation_id = ? AND artifact_key = ?
            """, arguments: [conversationID, artifactKey])
    }
    /// The artifact keys of a conversation that are pinned as knowledge.
    package static func keptKeys(_ db: Database, conversationID: Int64) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: """
            SELECT artifact_key FROM chat_knowledge_artifacts WHERE conversation_id = ?
            """, arguments: [conversationID]))
    }
    static func encodeMeta(_ meta: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(meta)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw DatabaseError(message: "meta JSON encoding produced non-UTF-8 data")
        }
        return json
    }
}

extension ArtifactCommentQueries {
    @discardableResult
    package static func add(
        _ db: Database,
        conversationID: Int64,
        key: String,
        version: Int,
        anchor: CommentAnchor,
        body: String,
        now: Date = Date()
    ) throws -> Int64 {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtifactCommentError.emptyQuote
        }
        try db.execute(sql: """
            INSERT INTO chat_artifact_comments
                (conversation_id, artifact_key, artifact_version, body,
                 anchor_quote, anchor_prefix, anchor_suffix, anchor_heading, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, key, version, trimmed,
                             anchor.quote, anchor.prefix, anchor.suffix, anchor.heading, now.timeIntervalSince1970])
        return db.lastInsertedRowID
    }
    /// An unsent comment is the owner's private draft: deleting it leaves no
    /// trace. A sent one is part of the conversation — it can only be resolved.
    @discardableResult
    package static func deleteUnsent(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM chat_artifact_comments WHERE id = ? AND status = 'open'", arguments: [id])
        return db.changesCount > 0
    }
    @discardableResult
    package static func resolve(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE chat_artifact_comments SET status = 'resolved' WHERE id = ? AND status IN ('sent', 'outdated')
            """, arguments: [id])
        return db.changesCount > 0
    }
    /// Marks exactly `ids` sent, and only those still unsent — a comment added
    /// after the message was composed, or one sent earlier, is never touched.
    /// Runs inside the transaction that persists the owner message.
    @discardableResult
    package static func markSent(_ db: Database, ids: [Int64], at date: Date) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var arguments: StatementArguments = [date.timeIntervalSince1970]
        arguments += StatementArguments(ids)
        try db.execute(sql: """
            UPDATE chat_artifact_comments SET status = 'sent', sent_at = ?
            WHERE status = 'open' AND id IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: arguments)
        return db.changesCount
    }
    /// Applies a re-anchor plan: found live comments move onto `version`, lost
    /// ones become outdated (keeping the version they were last found on).
    /// Resolved and outdated rows are never touched.
    package static func apply(_ db: Database, plan: ArtifactCommentReanchor.Plan, version: Int) throws {
        for id in plan.moved {
            try db.execute(sql: """
                UPDATE chat_artifact_comments SET artifact_version = ? WHERE id = ? AND status IN ('open', 'sent')
                """, arguments: [version, id])
        }
        for id in plan.lost {
            try db.execute(sql: """
                UPDATE chat_artifact_comments SET status = 'outdated' WHERE id = ? AND status IN ('open', 'sent')
                """, arguments: [id])
        }
    }
}

extension ChatAttachmentQueries {
    static func ownerColumns(_ owner: ChatAttachmentOwner) -> (conversationID: Int64?, projectID: Int64?) {
        switch owner {
        case .conversation(let id): return (id, nil)
        case .project(let id): return (nil, id)
        }
    }
    package static func insert(
        _ db: Database,
        owner: ChatAttachmentOwner,
        name: String,
        mime: String,
        size: Int64,
        path: String,
        sha256: String
    ) throws -> ChatAttachment {
        let columns = ownerColumns(owner)
        try db.execute(sql: """
            INSERT INTO chat_attachments (conversation_id, project_id, name, mime, size, path, sha256, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [columns.conversationID, columns.projectID, name, mime, size, path, sha256,
                             Date().timeIntervalSince1970])
        guard let row = try ChatAttachment.fetchOne(
            db, sql: "SELECT * FROM chat_attachments WHERE id = ?", arguments: [db.lastInsertedRowID]) else {
            throw DatabaseError(message: "chat attachment missing right after insert")
        }
        return row
    }
    /// A stored file with this content for the same owner (storage dedupe).
    package static func existingPath(_ db: Database, owner: ChatAttachmentOwner, sha256: String) throws -> String? {
        switch owner {
        case .conversation(let id):
            return try String.fetchOne(db, sql: """
                SELECT path FROM chat_attachments WHERE conversation_id = ? AND sha256 = ? ORDER BY id LIMIT 1
                """, arguments: [id, sha256])
        case .project(let id):
            return try String.fetchOne(db, sql: """
                SELECT path FROM chat_attachments WHERE project_id = ? AND sha256 = ? ORDER BY id LIMIT 1
                """, arguments: [id, sha256])
        }
    }
    /// Links pending (message-less) rows to the message they were sent with.
    /// Never steals a row a previous link already claimed.
    package static func link(_ db: Database, attachmentIDs: [Int64], messageID: Int64) throws {
        guard !attachmentIDs.isEmpty else { return }
        var arguments: StatementArguments = [messageID]
        arguments += StatementArguments(attachmentIDs)
        try db.execute(sql: """
            UPDATE chat_attachments SET message_id = ?
            WHERE id IN (\(databaseQuestionMarks(count: attachmentIDs.count))) AND message_id IS NULL
            """, arguments: arguments)
    }
    /// A conversation's unsent files (not linked to any message yet): the
    /// composer's pending set when that conversation is opened again.
    package static func fetchPending(_ db: Database, conversationID: Int64) throws -> [ChatAttachment] {
        try ChatAttachment.fetchAll(db, sql: """
            SELECT * FROM chat_attachments WHERE conversation_id = ? AND message_id IS NULL ORDER BY id
            """, arguments: [conversationID])
    }
}
