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
            guard let dbPool = pool.value else {
                preconditionFailure("a database chat was requested before the database opened")
            }
            store = DatabaseEmbeddedChatStore(dbPool: dbPool, conversationID: conversationID)
        }
        return EmbeddedChatEngine(spec: spec, store: store, aiService: WatchtowerAIService(), gate: gate,
                                  draftMirror: spec.persistence == .memory ? nil : draftMirror)
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
