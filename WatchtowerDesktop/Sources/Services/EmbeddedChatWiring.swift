import Foundation
import GRDB
import WatchtowerCore

/// Owns `AppState.embeddedChatCenter` and builds the engines it hands out: a
/// database chat writes through the pool opened at launch, a memory chat
/// keeps its rows in the engine; every turn goes through `watchtower ai query`.
@MainActor
final class EmbeddedChatEngineFactory {
    /// Set once the database opens. A database chat is only ever requested
    /// with a conversation id read from this same pool, so it is always set
    /// by then.
    var dbPool: DatabasePool? {
        get { pool.value }
        set {
            pool.value = newValue
            remember.center = newValue.flatMap { pool in
                ProcessCLIRunner.makeDefault().map { RememberCenter(cli: WorkbenchCLI(runner: $0), dbPool: pool) }
            }
            remember.knowledge = newValue.map { ChatKnowledgeCenter(dbPool: $0) }
        }
    }
    /// Remember in place for every chat that carries the owner's
    /// instructions (the main chat is wired in `AppState+Remember`); nil
    /// until the database opens.
    var rememberCenter: RememberCenter? { remember.center }
    /// Decisions and facts saved in place, for the same chats; nil until the
    /// database opens.
    var knowledgeCenter: ChatKnowledgeCenter? { remember.knowledge }

    /// A stored owner message of a chat with the owner's instructions: each
    /// center acts on its own prefix only (remember, or a knowledge prefix).
    func ownerMessageStored(text: String, conversationID: Int64, messageID: Int64) {
        remember.ownerMessageStored(text: text, conversationID: conversationID, messageID: messageID)
    }
    private let remember: RememberBox
    let center: EmbeddedChatCenter
    private let pool: PoolBox

    init() {
        let pool = PoolBox()
        let mirror = UserDefaultsDraftMirror()
        let remember = RememberBox()
        self.pool = pool
        self.remember = remember
        center = EmbeddedChatCenter { spec, gate in
            Self.makeEngine(spec: spec, gate: gate, pool: pool, draftMirror: mirror, remember: remember)
        }
    }

    private static func makeEngine(
        spec: ChatSurfaceSpec,
        gate: EmbeddedStreamGate,
        pool: PoolBox,
        draftMirror: UserDefaultsDraftMirror,
        remember: RememberBox
    ) -> EmbeddedChatEngine {
        let store: EmbeddedChatStore
        switch spec.persistence {
        case .memory:
            store = MemoryEmbeddedChatStore()
        case .database(let conversationID):
            if let dbPool = pool.value {
                store = DatabaseEmbeddedChatStore(dbPool: dbPool, conversationID: conversationID)
            } else {
                // Unreachable while ids come from this pool; if it ever is
                // not, the chat shows an error instead of crashing the app.
                store = UnavailableEmbeddedChatStore()
            }
        }
        let engine = EmbeddedChatEngine(spec: spec, store: store, aiService: WatchtowerAIService(), gate: gate,
                                        draftMirror: spec.persistence == .memory ? nil : draftMirror,
                                        provider: Constants.aiProviderID())
        engine.onOwnerMessageStored = { [weak remember] text, conversationID, messageID in
            remember?.ownerMessageStored(text: text, conversationID: conversationID, messageID: messageID)
        }
        return engine
    }

    @MainActor
    private final class RememberBox {
        var center: RememberCenter?
        var knowledge: ChatKnowledgeCenter?

        func ownerMessageStored(text: String, conversationID: Int64, messageID: Int64) {
            center?.ownerMessageSent(text: text, conversationID: conversationID, messageID: messageID)
            knowledge?.ownerMessageSent(text: text, conversationID: conversationID, messageID: messageID)
        }
    }

    @MainActor
    private final class PoolBox {
        var value: DatabasePool?
    }
}

/// A queued owner message per chat, kept in `UserDefaults` so an app quit
/// before its turn starts brings it back as an unsent draft.
@MainActor
final class UserDefaultsDraftMirror: EmbeddedDraftMirror {
    private let defaults: UserDefaults
    private static let prefix = "embeddedChat.queuedDraft."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ text: String, for key: EmbeddedChatKey) {
        defaults.set(text, forKey: Self.prefix + key.description)
    }

    func clear(for key: EmbeddedChatKey) {
        defaults.removeObject(forKey: Self.prefix + key.description)
    }

    func restore(for key: EmbeddedChatKey) -> String? {
        defaults.string(forKey: Self.prefix + key.description)
    }
}

/// The store of a database chat requested before the database opened: every
/// read and write fails with a reason the chat shows.
@MainActor
private final class UnavailableEmbeddedChatStore: EmbeddedChatStore {
    struct DatabaseNotOpenError: LocalizedError {
        var errorDescription: String? { "The database isn't open yet." }
    }

    var dbPath: String? { nil }
    func loadMessages() throws -> [ChatMessageRecord] { throw DatabaseNotOpenError() }
    func loadSessionID() throws -> String? { throw DatabaseNotOpenError() }
    func beginTurn(ownerText: String?, turnID: String, provider: String?) async throws -> (ownerID: Int64?, assistantID: Int64) {
        throw DatabaseNotOpenError()
    }
    func saveProgress(messageID: Int64, text: String) async throws { throw DatabaseNotOpenError() }
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws {
        throw DatabaseNotOpenError()
    }
    func append(role: String, text: String) async throws -> Int64 { throw DatabaseNotOpenError() }
    func saveSessionID(_ sessionID: String?) async throws { throw DatabaseNotOpenError() }
}
