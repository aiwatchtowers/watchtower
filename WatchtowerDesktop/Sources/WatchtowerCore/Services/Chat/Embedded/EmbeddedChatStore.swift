import Foundation
import GRDB
import WatchtowerInterface

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
    func actions(turnID: String) throws -> [AgentAction]
    func saveActual(messageID: Int64, provider: String, model: String) async throws
    func saveProgress(messageID: Int64, text: String) async throws
    /// `status`: complete | partial | error. A `complete` reply also touches
    /// the conversation (its `updated_at` orders the target's tabs).
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws
    @discardableResult
    func append(role: String, text: String) async throws -> Int64
    /// A reply's tool step, written as it starts and as it ends (CHAT-02's
    /// "as it happens" for a database chat), and the turn's usage (written
    /// just before the reply's final state).
    func stepStarted(messageID: Int64, seq: Int, start: ChatToolStart, at date: Date) async throws
    func stepFinished(messageID: Int64, end: ChatToolEnd, at date: Date) async throws
    func saveUsage(messageID: Int64, usage: ChatUsage) async throws
    /// The stored steps of these replies, by message id.
    func steps(messageIDs: [Int64]) throws -> [Int64: [ChatTurnStep]]
    /// The `sqlite` path handed to `ai query --db-path`; nil for a chat that
    /// reads no workspace data.
    var dbPath: String? { get }
    /// The turn's process saves the turn (`ai query --persist`, mobile Inbox
    /// spec §8): the engine never calls `beginTurn` and no step, progress,
    /// actual or usage write — the process writes them; `finalize` and
    /// `append` record what the Mac makes of the reply afterwards.
    var persistedConversationID: Int64? { get }
}

extension EmbeddedChatStore {
    package var persistedConversationID: Int64? { nil }
    package func actions(turnID: String) throws -> [AgentAction] { [] }
    package func saveActual(messageID: Int64, provider: String, model: String) async throws {}
    // A store that keeps no steps or usage (the memory store: its steps are
    // shown while the turn runs, and a finished row has none).
    package func stepStarted(messageID: Int64, seq: Int, start: ChatToolStart, at date: Date) async throws {}
    package func stepFinished(messageID: Int64, end: ChatToolEnd, at date: Date) async throws {}
    package func saveUsage(messageID: Int64, usage: ChatUsage) async throws {}
    package func steps(messageIDs: [Int64]) throws -> [Int64: [ChatTurnStep]] { [:] }
}

/// A database chat: its turns are saved by their own `ai query --persist`
/// process; the Mac's own writes after a turn (the shown reply, a failure,
/// a notice) go through `chat.reply.finish` and `chat.message.append`.
@MainActor
package final class DatabaseEmbeddedChatStore: EmbeddedChatStore {
    private let dbPool: DatabasePool
    private let conversationID: Int64
    private let writes: ChatWrites

    package init(dbPool: DatabasePool, writes: ChatWrites, conversationID: Int64) {
        self.dbPool = dbPool
        self.writes = writes
        self.conversationID = conversationID
    }

    package var dbPath: String? { dbPool.path }
    package var persistedConversationID: Int64? { conversationID }

    package func actions(turnID: String) throws -> [AgentAction] {
        try dbPool.read { db in
            try AgentActionQueries.fetchByConversation(db, conversationID: conversationID).filter { $0.turnID == turnID }
        }
    }

    /// The conversation a context already has, read at once (no write, so
    /// no waiting on the write lock); nil when it has none yet.
    package nonisolated static func existingConversationID(
        dbPool: DatabasePool, contextType: String, contextID: String
    ) throws -> Int64? {
        try dbPool.read { db in try ChatConversationQueries.fetchByContext(db, type: contextType, id: contextID)?.id }
    }

    /// The conversation of one embedded chat context (a track, an idea, a
    /// recording), created with `title` on first use (`chat.new` with a
    /// reused context: Go finds or creates it). Reads first.
    package nonisolated static func conversationID(
        dbPool: DatabasePool, writes: ChatWrites, contextType: String, contextID: String, title: String
    ) async throws -> Int64 {
        if let existing = try await dbPool.read({ db in
            try ChatConversationQueries.fetchByContext(db, type: contextType, id: contextID)
        }) {
            return existing.id
        }
        let created: ChatNewResponse = try await writes.send(.chatNew) {
            ChatNewRequest(requestID: $0, context: ChatContext(type: contextType, id: contextID, title: title, reuse: true))
        }
        return created.conversationID
    }

    /// A new automation's draft chat becomes the saved automation's chat
    /// (spec 2026-10-24 §4, ask #528): `chat.context` moves the
    /// `automation_draft` conversation to `toContextType`/`contextID`. A
    /// conversation the target context already has wins when it holds
    /// messages (false: nothing moves); an empty one is deleted first. True
    /// when the row moved.
    package nonisolated static func rekeyConversation(
        writes: ChatWrites, conversationID: Int64, toContextType: String, contextID: String
    ) async throws -> Bool {
        let moved: ChatChanged = try await writes.send(.chatContext) {
            ChatContextRequest(requestID: $0, conversationID: conversationID, contextType: toContextType,
                               contextID: contextID)
        }
        return moved.changed
    }

    package func steps(messageIDs: [Int64]) throws -> [Int64: [ChatTurnStep]] {
        try dbPool.read { db in try ChatStepQueries.fetch(db, messageIDs: messageIDs) }
    }

    package func loadMessages() throws -> [ChatMessageRecord] {
        let id = conversationID
        return try dbPool.read { db in
            guard try ChatConversationQueries.fetchByID(db, id: id) != nil else { throw ChatContextGoneError() }
            return try ChatMessageQueries.fetchByConversation(db, conversationID: id)
        }
    }

    /// Never called: the turn's process writes its rows.
    package func beginTurn(ownerText: String?, turnID: String, provider: String?) async throws -> (ownerID: Int64?, assistantID: Int64) {
        throw ChatWriteError(sentence: "This chat's turns are saved by their own process.")
    }

    /// The process flushes the streamed text itself.
    package func saveProgress(messageID: Int64, text: String) async throws {}

    package func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws {
        let id = conversationID
        do {
            let _: ChatDone = try await writes.send(.chatReplyFinish) {
                ChatReplyFinishRequest(requestID: $0, conversationID: id, messageID: messageID, text: text,
                                       status: status, errorCode: errorCode, errorMessage: errorMessage)
            }
        } catch let error as ChatWriteError where error.isGone {
            throw ChatContextGoneError()
        }
    }

    @discardableResult
    package func append(role: String, text: String) async throws -> Int64 {
        let id = conversationID
        do {
            let added: ChatMessageAppendResponse = try await writes.send(.chatMessageAppend) {
                ChatMessageAppendRequest(requestID: $0, conversationID: id, role: role, text: text)
            }
            return added.messageID
        } catch let error as ChatWriteError where error.isGone {
            throw ChatContextGoneError()
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

    package func saveActual(messageID: Int64, provider: String, model: String) async throws {
        guard !provider.isEmpty else { return }
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: row.text, createdAt: row.createdAt,
                              turnID: row.turnID, status: row.status, provider: provider, model: model,
                              errorCode: row.errorCode, errorMessage: row.errorMessage)
        }
    }

    package func saveProgress(messageID: Int64, text: String) async throws {
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: text, createdAt: row.createdAt,
                              turnID: row.turnID, status: row.status, provider: row.provider, model: row.model)
        }
    }

    package func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws {
        try update(messageID) { row in
            ChatMessageRecord(id: row.id, conversationID: 0, role: row.role, text: text, createdAt: row.createdAt,
                              turnID: row.turnID, status: status, provider: row.provider, model: row.model,
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
