import Foundation
import GRDB
import WatchtowerCore
import WatchtowerChatText

// The Swift chat writers the Desktop no longer has (mobile Inbox spec §8:
// every chat write is Go's now), kept for tests only: they seed fixtures
// and stand in for the Go writer where a test drives the Mac against a fake
// session (`FakeChatSessionProcess` in persist mode, `FakeChatTower`). Their
// SQL is what `internal/chatstore/testdata/chat_writes.json` and
// `chat_turn_cases.json` pin on the Go side.

extension ChatConversationQueries {
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

    /// The owner saw this chat (Chats panel spec §5.2): `read_at` becomes
    /// "read through" the `created_at` of its last complete answer on the
    /// active branch (`ChatHistoryQueries.lastAnswerAt`), not the clock — an
    /// answer still streaming (a `partial` row, created when its turn began)
    /// is not covered, so its completion off screen leaves the chat unread.
    /// No complete answer yet = nothing changes. Never moves the mark back,
    /// and leaves `updated_at` alone: reading is not activity. Unchecked — a
    /// chat deleted meanwhile needs no mark.
    package static func markRead(_ db: Database, id: Int64) throws {
        guard let through = try ChatHistoryQueries.lastAnswerAt(db, conversationID: id) else { return }
        try db.execute(sql: """
            UPDATE chat_conversations SET read_at = MAX(COALESCE(read_at, 0), ?) WHERE id = ?
            """, arguments: [through, id])
    }

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [id])
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

extension ChatLeaseQueries {
    /// Takes the conversation's lease inside the caller's write transaction
    /// (`BEGIN IMMEDIATE`, so the first commit wins). Succeeds only when the
    /// row is absent or its heartbeat is older than `staleAfterMS` at
    /// `nowMS`; a taken-over row starts fresh (its cancel request is
    /// dropped). False: refused, the caller rolls back.
    package static func claim(_ db: Database, _ lease: ChatLease, nowMS: Int64) throws -> Bool {
        try db.execute(sql: """
            INSERT INTO chat_turn_leases
              (conversation_id, owner, owner_id, turn_id, started_at_ms, heartbeat_at_ms, cancel_requested_at_ms)
            VALUES (?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(conversation_id) DO UPDATE SET
              owner = excluded.owner, owner_id = excluded.owner_id, turn_id = excluded.turn_id,
              started_at_ms = excluded.started_at_ms, heartbeat_at_ms = excluded.heartbeat_at_ms,
              cancel_requested_at_ms = NULL
            WHERE chat_turn_leases.heartbeat_at_ms < ? - ?
            """, arguments: [lease.conversationID, lease.owner.rawValue, lease.ownerID, lease.turnID,
                             lease.startedAtMS, lease.heartbeatAtMS, nowMS, ChatLease.staleAfterMS])
        return db.changesCount == 1
    }

    /// Refreshes `turnID`'s lease; false: the row is gone or another turn's
    /// (the conversation was deleted, or the lease was taken over).
    package static func heartbeat(_ db: Database, conversationID: Int64, turnID: String, nowMS: Int64) throws -> Bool {
        try db.execute(sql: "UPDATE chat_turn_leases SET heartbeat_at_ms = ? WHERE conversation_id = ? AND turn_id = ?",
                       arguments: [nowMS, conversationID, turnID])
        return db.changesCount == 1
    }

    /// The other side's Stop: marks `turnID`'s lease cancel-requested;
    /// false: no such lease (the turn already ended).
    package static func requestCancel(_ db: Database, conversationID: Int64, turnID: String, nowMS: Int64) throws -> Bool {
        try db.execute(sql: "UPDATE chat_turn_leases SET cancel_requested_at_ms = ? WHERE conversation_id = ? AND turn_id = ?",
                       arguments: [nowMS, conversationID, turnID])
        return db.changesCount == 1
    }

    /// Deletes `turnID`'s lease inside the finalize transaction; another
    /// turn's lease is left alone.
    package static func release(_ db: Database, conversationID: Int64, turnID: String) throws {
        try db.execute(sql: "DELETE FROM chat_turn_leases WHERE conversation_id = ? AND turn_id = ?",
                       arguments: [conversationID, turnID])
    }

    /// Deletes every lease one owner process holds; returns how many.
    @discardableResult
    package static func releaseOwned(_ db: Database, owner: ChatLease.Owner, ownerID: String) throws -> Int {
        try db.execute(sql: "DELETE FROM chat_turn_leases WHERE owner = ? AND owner_id = ?",
                       arguments: [owner.rawValue, ownerID])
        return db.changesCount
    }

    /// At launch: the Desktop leases an earlier launch left behind (a
    /// crash), i.e. `owner = 'desktop'` held by any launch but this one.
    @discardableResult
    package static func releaseEarlierDesktopLaunches(_ db: Database, currentLaunchID: String) throws -> Int {
        try db.execute(sql: "DELETE FROM chat_turn_leases WHERE owner = 'desktop' AND owner_id <> ?",
                       arguments: [currentLaunchID])
        return db.changesCount
    }
}

extension ChatMessageQueries {
    @discardableResult
    package static func insert(_ db: Database, conversationID: Int64, role: String, text: String, turnID: String = "") throws -> Int64 {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, ?, ?, ?, ?)
        """, arguments: [conversationID, role, text, now, turnID])
        return db.lastInsertedRowID
    }

    package static func deleteByConversation(_ db: Database, conversationID: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_messages WHERE conversation_id = ?", arguments: [conversationID])
    }

    /// The owner row (when there is one) and the reply's empty `partial`
    /// placeholder, in one transaction — the owner text is on disk before the
    /// turn is sent. Throws `ChatContextGoneError` when the conversation is gone.
    package static func beginEmbeddedTurn(
        _ db: Database, conversationID: Int64, ownerText: String?, turnID: String, provider: String?, now: Double
    ) throws -> (ownerID: Int64?, assistantID: Int64) {
        try requireConversation(db, id: conversationID)
        var ownerID: Int64?
        if let ownerText {
            try db.execute(sql: """
                INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id) VALUES (?, 'user', ?, ?, ?)
                """, arguments: [conversationID, ownerText, now, turnID])
            ownerID = db.lastInsertedRowID
        }
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, created_at, turn_id, status, provider)
            VALUES (?, 'assistant', '', ?, ?, 'partial', ?)
            """, arguments: [conversationID, now, turnID, provider])
        return (ownerID, db.lastInsertedRowID)
    }

    /// Streamed text so far; the row stays `partial`.
    package static func saveEmbeddedProgress(_ db: Database, messageID: Int64, text: String) throws {
        try db.execute(sql: "UPDATE chat_messages SET text = ? WHERE id = ?", arguments: [text, messageID])
        guard db.changesCount > 0 else { throw ChatContextGoneError() }
    }

    /// An embedded reply's token counts, and its model when the usage names one.
    package static func saveEmbeddedUsage(_ db: Database, messageID: Int64, usage: ChatUsage) throws {
        try db.execute(sql: "UPDATE chat_messages SET tokens_in = ?, tokens_out = ? WHERE id = ?",
                       arguments: [usage.tokensIn, usage.tokensOut, messageID])
        guard db.changesCount > 0 else { throw ChatContextGoneError() }
        if !usage.model.isEmpty {
            try db.execute(sql: "UPDATE chat_messages SET model = ? WHERE id = ?", arguments: [usage.model, messageID])
        }
    }

    package static func finalizeEmbedded(
        _ db: Database, messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?
    ) throws {
        try db.execute(sql: """
            UPDATE chat_messages SET text = ?, status = ?, error_code = ?, error_message = ? WHERE id = ?
            """, arguments: [text, status, errorCode, errorMessage, messageID])
        guard db.changesCount > 0 else { throw ChatContextGoneError() }
    }

    package static func requireConversation(_ db: Database, id: Int64) throws {
        let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM chat_conversations WHERE id = ?)",
                                       arguments: [id]) ?? false
        guard exists else { throw ChatContextGoneError() }
    }
}

extension ChatProjectQueries {
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

    package static func touch(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET updated_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }
}

extension ChatStepQueries {
    package static func upsertStart(
        _ db: Database, messageID: Int64, seq: Int, toolID: String, name: String, argsJSON: String, startedAt: Double
    ) throws {
        if let existing = try Int64.fetchOne(
            db, sql: "SELECT id FROM chat_turn_steps WHERE message_id = ? AND tool_id = ?", arguments: [messageID, toolID]
        ) {
            try db.execute(
                sql: "UPDATE chat_turn_steps SET name = ?, args_json = ?, started_at = ? WHERE id = ?",
                arguments: [name, argsJSON, startedAt, existing]
            )
            return
        }
        try db.execute(sql: """
            INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, args_json, started_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [messageID, seq, toolID, name, argsJSON, startedAt])
    }

    package static func finish(
        _ db: Database, messageID: Int64, toolID: String, ok: Bool, summary: String, sourcesJSON: String, endedAt: Double
    ) throws {
        try db.execute(sql: """
            UPDATE chat_turn_steps SET ok = ?, summary = ?, sources_json = ?, ended_at = ?
            WHERE message_id = ? AND tool_id = ?
            """, arguments: [ok ? 1 : 0, summary, sourcesJSON, endedAt, messageID, toolID])
        guard db.changesCount == 0 else { return }
        // A tool_end whose tool_start never arrived is still a visible step (CHAT-02).
        let seq = try Int.fetchOne(
            db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM chat_turn_steps WHERE message_id = ?", arguments: [messageID]
        ) ?? 0
        try db.execute(sql: """
            INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, sources_json, started_at, ended_at)
            VALUES (?, ?, ?, '', ?, ?, ?, ?, ?)
            """, arguments: [messageID, seq, toolID, ok ? 1 : 0, summary, sourcesJSON, endedAt, endedAt])
    }
}

extension ChatTreeQueries {
    package struct NewMessage {
        let conversationID: Int64
        let parentID: Int64?
        let role: String
        let text: String
        let turnID: String
        let status: String
        let provider: String?
        let model: String?
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

    package static func insert(_ db: Database, _ m: NewMessage) throws -> ChatMessageRecord {
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

    /// Parses a finished assistant message (`final: true`) and stores every artifact.
    @discardableResult
    package static func persistArtifacts(
        _ db: Database, conversationID: Int64, messageID: Int64, text: String
    ) throws -> [ChatArtifact] {
        try ArtifactParser.parse(text, final: true).artifacts.map {
            try saveVersion(db, conversationID: conversationID, messageID: messageID, draft: $0, edited: false)
        }
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

    package static func encodeMeta(_ meta: [String: String]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(meta)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw DatabaseError(message: "meta JSON encoding produced non-UTF-8 data")
        }
        return json
    }
}

extension ChatAttachmentQueries {
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

    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_attachments WHERE id = ?", arguments: [id])
    }

    package static func referenceCount(_ db: Database, path: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_attachments WHERE path = ?", arguments: [path]) ?? 0
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

extension QueuedDraftQueries {
    /// Stores (or replaces) the surface's queued text.
    package static func save(_ db: Database, key: String, text: String, at: Date) throws {
        try db.execute(sql: """
            INSERT INTO chat_queued_drafts (surface_key, text, at) VALUES (?, ?, ?)
            ON CONFLICT(surface_key) DO UPDATE SET text = excluded.text, at = excluded.at
            """, arguments: [key, text, at.timeIntervalSince1970])
    }

    /// Removes the surface's queued text; a missing row is fine.
    package static func clear(_ db: Database, key: String) throws {
        try db.execute(sql: "DELETE FROM chat_queued_drafts WHERE surface_key = ?", arguments: [key])
    }
}

extension LiveSlackMark {
    /// Marks the conversation of `messageID` when a step with this name starts.
    package static func markIfSlackStep(_ db: Database, messageID: Int64, name: String) throws {
        guard isSlackConnectorStep(name) else { return }
        try db.execute(sql: """
            UPDATE chat_conversations SET live_slack_since = ?
            WHERE id = (SELECT conversation_id FROM chat_messages WHERE id = ?) AND live_slack_since IS NULL
            """, arguments: [messageID, messageID])
    }

    /// Marks the conversation when the turn's steps include a Slack connector
    /// call; an already marked conversation keeps its first mark.
    package static func markIfUsed(_ db: Database, conversationID: Int64, messageID: Int64) throws {
        let names = try String.fetchAll(db, sql: "SELECT name FROM chat_turn_steps WHERE message_id = ?", arguments: [messageID])
        guard names.contains(where: isSlackConnectorStep) else { return }
        try db.execute(sql: """
            UPDATE chat_conversations SET live_slack_since = ? WHERE id = ? AND live_slack_since IS NULL
            """, arguments: [messageID, conversationID])
    }
}

extension CodeQuestionList {
    /// Deletes the workbench's code questions that have no message at all
    /// and were created before `createdBefore` (unix seconds), except
    /// `keeping` (conversations a surface still holds); how many went.
    @discardableResult
    package static func deleteEmpty(
        _ db: Database, workbenchID: Int64, createdBefore: Double, keeping: Set<Int64> = []
    ) throws -> Int {
        let prefix = "\(workbenchID):"
        let candidates = try Int64.fetchAll(db, sql: """
            SELECT c.id FROM chat_conversations c
            WHERE c.context_type = ? AND \(ofWorkbench("c")) AND c.created_at < ? AND NOT \(hasMessage("c"))
            """, arguments: [contextType, prefix, prefix, createdBefore])
        var deleted = 0
        for id in candidates where !keeping.contains(id) {
            try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [id])
            deleted += db.changesCount
        }
        return deleted
    }

    /// Deletes a code question with its messages (and their search rows,
    /// through the cascade and the FTS triggers); true when one was deleted.
    @discardableResult
    package static func delete(_ db: Database, conversationID: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ? AND context_type = ?",
                       arguments: [conversationID, contextType])
        return db.changesCount > 0
    }
}

extension ReviewerThreadQueries {
    /// The thread's conversation, made with its row on first use. Read again
    /// inside the write: two sessions on one branch share one thread.
    package static func ensure(_ db: Database, projectID: Int64, branch: String) throws -> Int64 {
        if let existing = try conversationID(db, projectID: projectID, branch: branch) { return existing }
        let conversation = try ChatConversationQueries.create(
            db, title: "Reviewer: \(branch)", contextType: ReviewerSurface.contextType,
            contextID: ReviewerSurface.contextID(projectID: projectID, branch: branch))
        try db.execute(sql: """
            INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (?, ?, ?)
            """, arguments: [projectID, branch, conversation.id])
        return conversation.id
    }
}

extension ChatArtifactQueries {
    package static func fetch(_ db: Database, id: Int64) throws -> ChatArtifact {
        guard let artifact = try ChatArtifact.fetchOne(db, sql: "SELECT * FROM chat_artifacts WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat artifact \(id) missing right after write")
        }
        return artifact
    }
}

/// `keep` refused (LIVE-01): the conversation used the Live Slack connector.
package enum ChatArtifactKeepError: Error {
    case liveSlack
}
