import Foundation
import GRDB
import WatchtowerCore
import WatchtowerChatText

// The Swift chat writers the Desktop no longer has (mobile Inbox spec §8:
// every chat write is Go's now), kept for tests only: they seed fixtures
// and stand in for the Go writer where a test drives the Mac against a fake
// (`FakeEmbeddedPersist`, `FakeChatTower`). The main chat's writers the
// unified chat (#1822) moved here are in `ChatFixtureWriters.swift`; these
// are the rest. Their SQL is what `internal/chatstore/testdata/chat_writes.json`
// pins on the Go side.

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

extension ChatAttachmentQueries {
    package static func delete(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_attachments WHERE id = ?", arguments: [id])
    }

    package static func referenceCount(_ db: Database, path: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_attachments WHERE path = ?", arguments: [path]) ?? 0
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
    /// inside the write: two sessions on one branch of one folder share one thread.
    package static func ensure(_ db: Database, projectID: Int64, folderID: Int64? = nil, branch: String) throws -> Int64 {
        if let existing = try conversationID(db, projectID: projectID, folderID: folderID, branch: branch) { return existing }
        let conversation = try ChatConversationQueries.create(
            db, title: "Reviewer: \(branch)", contextType: ReviewerSurface.contextType,
            contextID: ReviewerSurface.contextID(projectID: projectID, folderID: folderID, branch: branch))
        let (folderSQL, folderArg) = folder(projectID: projectID, folderID: folderID)
        try db.execute(sql: """
            INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id)
            VALUES (?, \(folderSQL), ?, ?)
            """, arguments: [projectID, folderArg, branch, conversation.id])
        return conversation.id
    }
}
