import Foundation
import GRDB

/// Where an embedded chat keeps its rows. Every write throws — a failure is
/// shown to the owner, never swallowed.
@MainActor
package protocol EmbeddedChatStore: AnyObject {
    func loadMessages() throws -> [ChatMessageRecord]
    func loadSessionID() throws -> String?
    /// The owner row (nil for a follow-up or hidden prompt) plus the reply's
    /// empty `partial` placeholder, atomically.
    func beginTurn(ownerText: String?, turnID: String) throws -> (ownerID: Int64?, assistantID: Int64)
    func saveProgress(messageID: Int64, text: String) throws
    /// `status`: complete | partial | error. A `complete` reply also touches
    /// the conversation (its `updated_at` orders the target's tabs).
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) throws
    @discardableResult
    func append(role: String, text: String) throws -> Int64
    func saveSessionID(_ sessionID: String) throws
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

    package func loadMessages() throws -> [ChatMessageRecord] {
        let id = conversationID
        return try dbPool.read { db in try ChatMessageQueries.fetchByConversation(db, conversationID: id) }
    }

    package func loadSessionID() throws -> String? {
        let id = conversationID
        guard let conversation = try dbPool.read({ db in try ChatConversationQueries.fetchByID(db, id: id) }) else {
            throw ChatContextGoneError()
        }
        return conversation.sessionID
    }

    package func beginTurn(ownerText: String?, turnID: String) throws -> (ownerID: Int64?, assistantID: Int64) {
        let id = conversationID
        let now = clock().timeIntervalSince1970
        return try dbPool.write { db in
            try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: id, ownerText: ownerText, turnID: turnID, now: now)
        }
    }

    package func saveProgress(messageID: Int64, text: String) throws {
        try dbPool.write { db in try ChatMessageQueries.saveEmbeddedProgress(db, messageID: messageID, text: text) }
    }

    package func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) throws {
        let id = conversationID
        try dbPool.write { db in
            try ChatMessageQueries.finalizeEmbedded(db, messageID: messageID, text: text, status: status,
                                                    errorCode: errorCode, errorMessage: errorMessage)
            if status == "complete" { try ChatConversationQueries.touch(db, id: id) }
        }
    }

    @discardableResult
    package func append(role: String, text: String) throws -> Int64 {
        let id = conversationID
        return try dbPool.write { db in
            try ChatMessageQueries.requireConversation(db, id: id)
            return try ChatMessageQueries.insert(db, conversationID: id, role: role, text: text)
        }
    }

    package func saveSessionID(_ sessionID: String) throws {
        let id = conversationID
        try dbPool.write { db in
            try ChatConversationQueries.updateSessionID(db, id: id, sessionID: sessionID)
            guard db.changesCount > 0 else { throw ChatContextGoneError() }
        }
    }
}

/// Rows for a throwaway chat (onboarding, setup assistants): nothing is
/// written to disk. Synthetic ids are negative so they can never collide
/// with a persisted row.
@MainActor
package final class MemoryEmbeddedChatStore: EmbeddedChatStore {
    private var rows: [ChatMessageRecord] = []
    private var sessionID: String?
    private var nextID: Int64 = -1
    private let clock: () -> Date

    package init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    package var dbPath: String? { nil }

    package func loadMessages() throws -> [ChatMessageRecord] { rows }

    package func loadSessionID() throws -> String? { sessionID }

    package func beginTurn(ownerText: String?, turnID: String) throws -> (ownerID: Int64?, assistantID: Int64) {
        let ownerID = ownerText.map { insert(role: "user", text: $0, turnID: turnID, status: "complete") }
        let assistantID = insert(role: "assistant", text: "", turnID: turnID, status: "partial")
        return (ownerID, assistantID)
    }

    package func saveProgress(messageID: Int64, text: String) throws {
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: text, createdAt: row.createdAt,
                              turnID: row.turnID, status: row.status)
        }
    }

    package func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) throws {
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: text, createdAt: row.createdAt,
                              turnID: row.turnID, status: status, errorCode: errorCode, errorMessage: errorMessage)
        }
    }

    @discardableResult
    package func append(role: String, text: String) throws -> Int64 {
        insert(role: role, text: text, turnID: "", status: "complete")
    }

    package func saveSessionID(_ sessionID: String) throws {
        self.sessionID = sessionID
    }

    private func insert(role: String, text: String, turnID: String, status: String) -> Int64 {
        let id = nextID
        nextID -= 1
        rows.append(ChatMessageRecord(id: id, conversationID: 0, role: role, text: text,
                                      createdAt: clock().timeIntervalSince1970, turnID: turnID, status: status))
        return id
    }

    private func update(_ id: Int64, _ transform: (ChatMessageRecord) -> ChatMessageRecord) throws {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { throw ChatContextGoneError() }
        rows[index] = transform(rows[index])
    }
}
