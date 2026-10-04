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
        set { pool.value = newValue }
    }
    let center: EmbeddedChatCenter
    private let pool: PoolBox

    init() {
        let pool = PoolBox()
        let mirror = UserDefaultsDraftMirror()
        self.pool = pool
        center = EmbeddedChatCenter { spec, gate in
            Self.makeEngine(spec: spec, gate: gate, pool: pool, draftMirror: mirror)
        }
    }

    private static func makeEngine(
        spec: ChatSurfaceSpec,
        gate: EmbeddedStreamGate,
        pool: PoolBox,
        draftMirror: UserDefaultsDraftMirror
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
        return EmbeddedChatEngine(spec: spec, store: store, aiService: WatchtowerAIService(), gate: gate,
                                  draftMirror: spec.persistence == .memory ? nil : draftMirror,
                                  provider: Constants.aiProviderID())
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
    func beginTurn(ownerText: String?, turnID: String, provider: String?) throws -> (ownerID: Int64?, assistantID: Int64) {
        throw DatabaseNotOpenError()
    }
    func saveProgress(messageID: Int64, text: String) throws { throw DatabaseNotOpenError() }
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) throws {
        throw DatabaseNotOpenError()
    }
    func append(role: String, text: String) throws -> Int64 { throw DatabaseNotOpenError() }
    func saveSessionID(_ sessionID: String?) throws { throw DatabaseNotOpenError() }
}
