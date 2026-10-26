import Foundation
import GRDB

/// Where an embedded chat keeps its rows. Every write throws — a failure is
/// shown to the owner, never swallowed — and is `async`: a database store
/// awaits GRDB's writer queue, so another process's write lock never
/// freezes the main thread (board #670). The engine queues them in order.
@MainActor
package protocol EmbeddedChatStore: AnyObject {
    /// The chat's rows; a deleted context throws `ChatContextGoneError`.
    func loadMessages() throws -> [ChatMessageRecord]
    /// The owner row (nil for a follow-up or hidden prompt) plus the reply's
    /// empty `partial` placeholder, atomically.
    /// `provider` is stamped on the reply row (the error card's sign-in hint).
    func beginTurn(ownerText: String?, turnID: String, provider: String?) async throws -> (ownerID: Int64?, assistantID: Int64)
    func saveProgress(messageID: Int64, text: String) async throws
    /// `status`: complete | partial | error. A `complete` reply also touches
    /// the conversation (its `updated_at` orders the target's tabs).
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws
    @discardableResult
    func append(role: String, text: String) async throws -> Int64
    /// The `sqlite` path handed to `ai query --db-path`; nil for a chat that
    /// reads no workspace data.
    var dbPath: String? { get }
}

/// The existing `chat_messages`/`chat_conversations` columns, unchanged.
@MainActor
package final class DatabaseEmbeddedChatStore: EmbeddedChatStore {
    private let dbPool: DatabasePool
    private let conversationID: Int64
    private let clock: () -> Date

    package init(dbPool: DatabasePool, conversationID: Int64, clock: @escaping () -> Date = Date.init) {
        self.dbPool = dbPool
        self.conversationID = conversationID
        self.clock = clock
    }

    package var dbPath: String? { dbPool.path }

    /// The conversation a context already has, read at once (no write, so
    /// no waiting on the write lock); nil when it has none yet.
    package nonisolated static func existingConversationID(
        dbPool: DatabasePool, contextType: String, contextID: String
    ) throws -> Int64? {
        try dbPool.read { db in try ChatConversationQueries.fetchByContext(db, type: contextType, id: contextID)?.id }
    }

    /// The conversation of one embedded chat context (a track, an idea, a
    /// recording), created with `title` on first use. Reads first; the
    /// create awaits the writer off the main thread (board #670).
    package nonisolated static func conversationID(
        dbPool: DatabasePool, contextType: String, contextID: String, title: String
    ) async throws -> Int64 {
        if let existing = try await dbPool.read({ db in
            try ChatConversationQueries.fetchByContext(db, type: contextType, id: contextID)
        }) {
            return existing.id
        }
        return try await dbPool.write { db in
            // Re-checked inside the write: another screen may have created it.
            if let existing = try ChatConversationQueries.fetchByContext(db, type: contextType, id: contextID) {
                return existing.id
            }
            return try ChatConversationQueries.create(db, title: title, contextType: contextType, contextID: contextID).id
        }
    }

    /// A new automation's draft chat becomes the saved automation's chat
    /// (spec 2026-10-24 §4, ask #528): one write moves the `automation_draft`
    /// conversation to `toContextType`/`contextID`. A conversation the target
    /// context already has wins when it holds messages (false: nothing moves,
    /// nothing is merged or deleted); an empty one is deleted first, in the
    /// same transaction. True when the row moved.
    package nonisolated static func rekeyConversation(
        dbPool: DatabasePool, conversationID: Int64, toContextType: String, contextID: String
    ) async throws -> Bool {
        let now = Date().timeIntervalSince1970
        return try await dbPool.write { db in
            guard try ChatConversationQueries.fetchByID(db, id: conversationID)?.contextType
                == AutomationDraftRows.contextType else { return false }
            if let existing = try ChatConversationQueries.fetchByContext(db, type: toContextType, id: contextID) {
                let hasMessages = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM chat_messages WHERE conversation_id = ?)
                    """, arguments: [existing.id]) ?? false
                if hasMessages { return false }
                try ChatConversationQueries.delete(db, id: existing.id)
            }
            try db.execute(sql: """
                UPDATE chat_conversations SET context_type = ?, context_id = ?, updated_at = ?
                WHERE id = ? AND context_type = 'automation_draft'
                """, arguments: [toContextType, contextID, now, conversationID])
            return db.changesCount > 0
        }
    }

    package func loadMessages() throws -> [ChatMessageRecord] {
        let id = conversationID
        return try dbPool.read { db in
            guard try ChatConversationQueries.fetchByID(db, id: id) != nil else { throw ChatContextGoneError() }
            return try ChatMessageQueries.fetchByConversation(db, conversationID: id)
        }
    }

    package func beginTurn(ownerText: String?, turnID: String, provider: String?) async throws -> (ownerID: Int64?, assistantID: Int64) {
        let id = conversationID
        let now = clock().timeIntervalSince1970
        return try await dbPool.write { db in
            try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: id, ownerText: ownerText, turnID: turnID,
                                                     provider: provider, now: now)
        }
    }

    package func saveProgress(messageID: Int64, text: String) async throws {
        try await dbPool.write { db in try ChatMessageQueries.saveEmbeddedProgress(db, messageID: messageID, text: text) }
    }

    package func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws {
        let id = conversationID
        try await dbPool.write { db in
            try ChatMessageQueries.finalizeEmbedded(db, messageID: messageID, text: text, status: status,
                                                    errorCode: errorCode, errorMessage: errorMessage)
            if status == "complete" { try ChatConversationQueries.touch(db, id: id) }
        }
    }

    @discardableResult
    package func append(role: String, text: String) async throws -> Int64 {
        let id = conversationID
        return try await dbPool.write { db in
            try ChatMessageQueries.requireConversation(db, id: id)
            return try ChatMessageQueries.insert(db, conversationID: id, role: role, text: text)
        }
    }
}

/// Rows for a throwaway chat (onboarding, setup assistants): nothing is
/// written to disk. Synthetic ids are negative so they can never collide
/// with a persisted row.
@MainActor
package final class MemoryEmbeddedChatStore: EmbeddedChatStore {
    private var rows: [ChatMessageRecord] = []
    private var nextID: Int64 = -1
    private let clock: () -> Date

    package init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    package var dbPath: String? { nil }

    package func loadMessages() throws -> [ChatMessageRecord] { rows }

    package func beginTurn(ownerText: String?, turnID: String, provider: String?) async throws -> (ownerID: Int64?, assistantID: Int64) {
        let ownerID = ownerText.map { insert(role: "user", text: $0, turnID: turnID, status: "complete") }
        let assistantID = insert(role: "assistant", text: "", turnID: turnID, status: "partial", provider: provider)
        return (ownerID, assistantID)
    }

    package func saveProgress(messageID: Int64, text: String) async throws {
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: text, createdAt: row.createdAt,
                              turnID: row.turnID, status: row.status, provider: row.provider)
        }
    }

    package func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws {
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: text, createdAt: row.createdAt,
                              turnID: row.turnID, status: status, provider: row.provider,
                              errorCode: errorCode, errorMessage: errorMessage)
        }
    }

    @discardableResult
    package func append(role: String, text: String) async throws -> Int64 {
        insert(role: role, text: text, turnID: "", status: "complete")
    }

    private func insert(role: String, text: String, turnID: String, status: String, provider: String? = nil) -> Int64 {
        let id = nextID
        nextID -= 1
        rows.append(ChatMessageRecord(id: id, conversationID: 0, role: role, text: text,
                                      createdAt: clock().timeIntervalSince1970, turnID: turnID, status: status,
                                      provider: provider))
        return id
    }

    private func update(_ id: Int64, _ transform: (ChatMessageRecord) -> ChatMessageRecord) throws {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { throw ChatContextGoneError() }
        rows[index] = transform(rows[index])
    }
}
