import Foundation
import GRDB

/// The conversation of a running turn is gone (deleted on the Mac, from the
/// phone, or with its project): an update by message id changed no row, or
/// a child row failed its foreign key. The write rolled back; the turn
/// writes nothing more (spec 2026-11-15 §4.4).
package struct ChatConversationGoneError: Error, Equatable {
    package init() {}

    /// `error` says the conversation went away under the write.
    package static func matches(_ error: Error) -> Bool {
        if error is Self { return true }
        guard let db = error as? DatabaseError else { return false }
        return db.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY
    }
}

/// The writes a running turn makes. Only the lease holder writes these rows
/// (spec 2026-11-15 §8: this store, or the hub's Go twin); every write is
/// small and awaits GRDB's writer queue, so a write lock held by another
/// process never blocks the main thread (board #670). `ChatTurnDriver`
/// queues them in order.
package struct ChatTurnStore: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    package func saveProgress(messageID: Int64, text: String, status: String, usage: ChatUsage?, errorCode: String?) async throws {
        try await dbPool.write { db in
            try ChatTreeQueries.updateAssistant(db, id: messageID, text: text, status: status,
                                                tokensIn: usage?.tokensIn, tokensOut: usage?.tokensOut,
                                                errorCode: errorCode, errorMessage: nil)
            guard db.changesCount > 0 else { throw ChatConversationGoneError() }
            if let model = usage?.model, !model.isEmpty {
                try ChatTreeQueries.setModel(db, messageID: messageID, model: model)
            }
        }
    }

    package func saveActual(
        conversationID: Int64,
        messageID: Int64?,
        provider: String,
        model: String,
        routing: ChatRoutingMetadata?,
        projectID: Int64?
    ) async throws {
        guard !provider.isEmpty else { return }
        try await dbPool.write { db in
            // A late event from a retired prompt must not overwrite the moved chat.
            try db.execute(sql: """
                UPDATE chat_conversations SET actual_provider = ?, actual_model = ?, routing_reason = ?
                WHERE id = ? AND project_id IS ?
                """, arguments: [provider, model, routing?.reason ?? "", conversationID, projectID])
            if let messageID {
                try db.execute(sql: "UPDATE chat_messages SET provider = ?, model = ? WHERE id = ? AND conversation_id = ?",
                               arguments: [provider, model, messageID, conversationID])
            }
        }
    }

    package func stepStarted(messageID: Int64, seq: Int, start: ChatToolStart, at date: Date) async throws {
        try await dbPool.write { db in
            try ChatStepQueries.upsertStart(db, messageID: messageID, seq: seq, toolID: start.id, name: start.name,
                                            argsJSON: start.argsJSON, startedAt: date.timeIntervalSince1970)
            try LiveSlackMark.markIfSlackStep(db, messageID: messageID, name: start.name)
        }
    }

    package func stepFinished(messageID: Int64, end: ChatToolEnd, at date: Date) async throws {
        try await dbPool.write { db in
            try ChatStepQueries.finish(db, messageID: messageID, toolID: end.id, ok: end.ok, summary: end.summary,
                                       sourcesJSON: ChatSource.encodeList(end.sources), endedAt: date.timeIntervalSince1970)
        }
    }

    /// A session spawned for another project than the conversation's current
    /// one (the chat was moved mid-turn) records nothing: resuming it would
    /// skip the new project's prompt and files.
    package func saveSessionID(conversationID: Int64, sessionID: String, projectID: Int64?) async throws {
        try await dbPool.write { db in
            try ChatConversationQueries.updateSessionID(db, id: conversationID, sessionID: sessionID, projectID: projectID)
        }
    }

    /// The terminal write for a turn: saves the final message state AND
    /// versions its `:::artifact` blocks in ONE transaction, so a crash (or a
    /// write failure) can never leave a `complete`/`partial` message row with
    /// no corresponding `chat_artifacts` rows, or artifact rows with no
    /// matching message state — both writes commit or neither does. Called
    /// once per finished turn; `status == "error"` skips the artifact parse
    /// (an errored turn produces no artifacts). `error` is the failed turn's
    /// session error: its code and its own message are both kept.
    /// `turnID`'s lease is released in the same transaction (nil: a turn
    /// that holds none); a message gone with its conversation throws
    /// `ChatConversationGoneError` and nothing is written.
    @discardableResult
    package func finalizeTurn(
        conversationID: Int64,
        messageID: Int64,
        turnID: String? = nil,
        text: String,
        status: String,
        usage: ChatUsage?,
        error: ChatSessionError?
    ) async throws -> [ChatArtifact] {
        try await dbPool.write { db in
            try ChatTreeQueries.updateAssistant(db, id: messageID, text: text, status: status,
                                                tokensIn: usage?.tokensIn, tokensOut: usage?.tokensOut,
                                                errorCode: error?.persistenceCode, errorMessage: error?.message)
            guard db.changesCount > 0 else { throw ChatConversationGoneError() }
            if let turnID { try ChatLeaseQueries.release(db, conversationID: conversationID, turnID: turnID) }
            if let model = usage?.model, !model.isEmpty {
                try ChatTreeQueries.setModel(db, messageID: messageID, model: model)
            }
            try LiveSlackMark.markIfUsed(db, conversationID: conversationID, messageID: messageID)
            guard status != "error" else { return [] }
            return try ChatArtifactQueries.persistArtifacts(db, conversationID: conversationID, messageID: messageID, text: text)
        }
    }

    /// The lease watch's heartbeat (spec §4.4); false: the lease is gone or
    /// another turn's — the conversation was deleted or the lease taken.
    package func heartbeat(conversationID: Int64, turnID: String, nowMS: Int64) async throws -> Bool {
        try await dbPool.write { db in
            try ChatLeaseQueries.heartbeat(db, conversationID: conversationID, turnID: turnID, nowMS: nowMS)
        }
    }

    /// The conversation's lease as it stands (the cancel poll).
    package func lease(conversationID: Int64) async throws -> ChatLease? {
        try await dbPool.read { db in try ChatLeaseQueries.fetch(db, conversationID: conversationID) }
    }
}
