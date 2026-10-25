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
            draftMirror.writer = newValue
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
        remember.ownerMessageStored(text: text, conversationID: conversationID, messageID: messageID, savesKnowledge: true)
    }
    private let remember: RememberBox
    let center: EmbeddedChatCenter
    private let pool: PoolBox
    private let draftMirror: DatabaseDraftMirror

    init() {
        let pool = PoolBox()
        let mirror = DatabaseDraftMirror()
        draftMirror = mirror
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
        draftMirror: DatabaseDraftMirror,
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
        // A workbench code question never leaves its Questions tab (spec
        // 2026-10-02 §9.4): a knowledge prefix typed there saves nothing.
        // Remember still applies, as in every chat with the owner's instructions.
        let savesKnowledge = spec.key.contextType != CodeQuestionList.contextType
        engine.onOwnerMessageStored = { [weak remember] text, conversationID, messageID in
            remember?.ownerMessageStored(text: text, conversationID: conversationID, messageID: messageID,
                                         savesKnowledge: savesKnowledge)
        }
        return engine
    }

    @MainActor
    private final class RememberBox {
        var center: RememberCenter?
        var knowledge: ChatKnowledgeCenter?

        func ownerMessageStored(text: String, conversationID: Int64, messageID: Int64, savesKnowledge: Bool) {
            center?.ownerMessageSent(text: text, conversationID: conversationID, messageID: messageID)
            if savesKnowledge {
                knowledge?.ownerMessageSent(text: text, conversationID: conversationID, messageID: messageID)
            }
        }
    }

    @MainActor
    private final class PoolBox {
        var value: DatabasePool?
    }
}

/// A queued owner message per chat, kept in `chat_queued_drafts` (#604 S15)
/// so an app quit before its turn starts brings it back as an unsent draft
/// (CHAT-01). `restore` is synchronous: it answers from what this process saved
/// or cleared, else reads the row. A message queued before the database opens
/// stays in memory and is written once `writer` is set; setting it also moves
/// the legacy `embeddedChat.queuedDraft.*` defaults into the table.
@MainActor
final class DatabaseDraftMirror: EmbeddedDraftMirror {
    /// Set once the database opens.
    var writer: (any DatabaseWriter)? {
        didSet { if oldValue == nil, writer != nil { flushOnOpen() } }
    }
    private let defaults: UserDefaults
    static let legacyPrefix = "embeddedChat.queuedDraft."
    /// What this process saved (text) or cleared (nil), by surface key.
    private var known: [String: String?] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ text: String, for key: EmbeddedChatKey) {
        known[key.description] = .some(text)
        write([key.description: text])
    }

    func clear(for key: EmbeddedChatKey) {
        known[key.description] = .some(nil)
        write([key.description: nil])
    }

    func restore(for key: EmbeddedChatKey) -> String? {
        if let value = known[key.description] { return value }
        guard let writer else { return nil }
        do {
            return try writer.read { try QueuedDraftQueries.text($0, key: key.description) }
        } catch {
            NSLog("DatabaseDraftMirror: reading a queued draft failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Writes what was queued before the database opened, then the legacy
    /// defaults no write of this process superseded; the defaults go once the
    /// write commits, so a failed write keeps them for the next launch.
    private func flushOnOpen() {
        var changes = known
        var legacyKeys: [String] = []
        for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix(Self.legacyPrefix) {
            legacyKeys.append(name)
            let key = String(name.dropFirst(Self.legacyPrefix.count))
            if changes[key] == nil, let text = value as? String { changes[key] = .some(text) }
        }
        let defaults = defaults
        write(changes) { succeeded in
            guard succeeded else { return }
            for name in legacyKeys { defaults.removeObject(forKey: name) }
        }
    }

    /// One ordered write (GRDB runs async writes in call order, so a save and
    /// a later clear land in that order); nothing before the database opens.
    private func write(_ changes: [String: String?], completion: (@Sendable (Bool) -> Void)? = nil) {
        guard let writer, !changes.isEmpty else { return }
        let now = Date()
        writer.asyncWrite({ db in
            for (key, text) in changes {
                if let text {
                    try QueuedDraftQueries.save(db, key: key, text: text, at: now)
                } else {
                    try QueuedDraftQueries.clear(db, key: key)
                }
            }
        }, completion: { _, result in
            if case .failure(let error) = result {
                NSLog("DatabaseDraftMirror: writing a queued draft failed: %@", error.localizedDescription)
            }
            completion?(result.isSuccess)
        })
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
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
    func beginTurn(ownerText: String?, turnID: String, provider: String?) async throws -> (ownerID: Int64?, assistantID: Int64) {
        throw DatabaseNotOpenError()
    }
    func saveProgress(messageID: Int64, text: String) async throws { throw DatabaseNotOpenError() }
    func finalize(messageID: Int64, text: String, status: String, errorCode: String?, errorMessage: String?) async throws {
        throw DatabaseNotOpenError()
    }
    func append(role: String, text: String) async throws -> Int64 { throw DatabaseNotOpenError() }
}
