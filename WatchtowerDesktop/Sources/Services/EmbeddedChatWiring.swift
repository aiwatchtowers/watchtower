import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Owns `AppState.embeddedChatCenter` and builds the engines it hands out: a
/// database chat reads the pool opened at launch and its turns save
/// themselves (`ai query --persist`, the Mac's own writes through
/// `chatWrites`), a memory chat keeps its rows in the engine; every turn goes
/// through `watchtower ai query`.
@MainActor
final class EmbeddedChatEngineFactory {
    /// Set once the database opens. A database chat is only ever requested
    /// with a conversation id read from this same pool, so it is always set
    /// by then.
    var dbPool: DatabasePool? {
        get { pool.value }
        set {
            pool.value = newValue
            draftMirror.reader = newValue
            remember.center = newValue.flatMap { pool in
                ProcessCLIRunner.makeDefault().map { RememberCenter(cli: WorkbenchCLI(runner: $0), dbPool: pool) }
            }
            remember.knowledge = newValue.map { ChatKnowledgeCenter(dbPool: $0) }
        }
    }
    /// The chat writes (the tower); set with `dbPool`.
    var chatWrites: ChatWrites? {
        get { pool.writes }
        set {
            pool.writes = newValue
            draftMirror.writes = newValue
        }
    }
    /// Remember in place for every chat that carries the owner's
    /// instructions (the main chat is wired in `AppState+Remember`); nil
    /// until the database opens.
    var rememberCenter: RememberCenter? { remember.center }
    /// Decisions and facts saved in place, for the same chats; nil until the
    /// database opens.
    var knowledgeCenter: ChatKnowledgeCenter? { remember.knowledge }

    /// The main chat's started turn: Go ran remember and the knowledge
    /// prefixes in its start; the marks show what they did.
    func ownerMessageStarted(_ started: ChatStarted, text: String) {
        remember.center?.record(started, text: text)
        guard let knowledge = remember.knowledge else { return }
        Task { await knowledge.record(started, text: text) }
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
            if let dbPool = pool.value, let writes = pool.writes {
                store = DatabaseEmbeddedChatStore(dbPool: dbPool, writes: writes, conversationID: conversationID)
            } else {
                // Unreachable while ids come from this pool; if it ever is
                // not, the chat shows an error instead of crashing the app.
                store = UnavailableEmbeddedChatStore()
            }
        }
        let engine = EmbeddedChatEngine(spec: spec, store: store, aiService: WatchtowerAIService(), gate: gate,
                                        draftMirror: spec.persistence == .memory ? nil : draftMirror,
                                        provider: Constants.aiProviderID())
        let savesKnowledge = savesKnowledge(contextType: spec.key.contextType)
        engine.onOwnerMessageStored = { [weak remember] text, conversationID, messageID in
            remember?.ownerMessageStored(text: text, conversationID: conversationID, messageID: messageID,
                                         savesKnowledge: savesKnowledge)
        }
        return engine
    }

    /// Whether a knowledge prefix (`решили:`, `факт:`) typed in a chat of
    /// this context saves a decision or fact. A workbench code question
    /// never leaves its Questions tab (spec 2026-10-02 §9.4) and a spec
    /// review Discuss thread stays out of the ideas registry (spec
    /// 2026-11-08 §3), nor does Branch review's reviewer thread, which
    /// quotes the folder's code as a code question does (board #1025), nor
    /// does the tuning chat (spec 2026-11-03 §4.1), like the Go filters:
    /// there it saves nothing. Remember
    /// still applies, as in every chat with the owner's instructions.
    static func savesKnowledge(contextType: String) -> Bool {
        ![CodeQuestionList.contextType, SpecReviewThreadKey.contextType, ReviewerSurface.contextType,
          TuningChatSurface.contextType].contains(contextType)
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
        var writes: ChatWrites?
    }
}

/// A queued owner message per chat, kept in `chat_queued_drafts` (#604 S15)
/// so an app quit before its turn starts brings it back as an unsent draft
/// (CHAT-01). `restore` is synchronous: it answers from what this process saved
/// or cleared, else reads the row. A message queued before the database opens
/// stays in memory and is written once `writes` is set; setting it also moves
/// the legacy `embeddedChat.queuedDraft.*` defaults into the table. The
/// writes are `chat.draft.save` / `chat.draft.clear`, one after another.
@MainActor
final class DatabaseDraftMirror: EmbeddedDraftMirror {
    /// Set once the database opens.
    var reader: (any DatabaseReader)?
    /// Set once the database opens (with `reader`).
    var writes: ChatWrites? {
        didSet { if oldValue == nil, writes != nil { flushOnOpen() } }
    }
    private let defaults: UserDefaults
    static let legacyPrefix = "embeddedChat.queuedDraft."
    /// What this process saved (text) or cleared (nil), by surface key.
    private var known: [String: String?] = [:]
    private let chain = SerialWrites()

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
        guard let reader else { return nil }
        do {
            return try reader.read { try QueuedDraftQueries.text($0, key: key.description) }
        } catch {
            NSLog("DatabaseDraftMirror: reading a queued draft failed: %@", error.localizedDescription)
            return nil
        }
    }

    /// Returns once every write asked for so far has landed (tests).
    func writesSettled() async {
        await chain.idle()
    }

    /// Writes what was queued before the database opened, then the legacy
    /// defaults no write of this process superseded; the defaults go once the
    /// writes land, so a failed write keeps them for the next launch.
    private func flushOnOpen() {
        var changes = known
        var legacyKeys: [String] = []
        for (name, value) in defaults.dictionaryRepresentation() where name.hasPrefix(Self.legacyPrefix) {
            legacyKeys.append(name)
            let key = String(name.dropFirst(Self.legacyPrefix.count))
            if changes[key] == nil, let text = value as? String { changes[key] = .some(text) }
        }
        // `restore` answers from `known` until the write lands, so a legacy
        // draft is seen at once, not only after the row commits.
        known = changes
        let defaults = defaults
        write(changes) { succeeded in
            guard succeeded else { return }
            for name in legacyKeys { defaults.removeObject(forKey: name) }
        }
    }

    /// The changes in order, after every earlier one (a save and a later
    /// clear land in that order); nothing before the database opens.
    private func write(_ changes: [String: String?], completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let writes, !changes.isEmpty else { return }
        chain.start {
            var succeeded = true
            for (key, text) in changes {
                do {
                    if let text {
                        let _: ChatDone = try await writes.perform(.chatDraftSave) {
                            ChatDraftSaveRequest(requestID: $0, surfaceKey: key, text: text)
                        }
                    } else {
                        let _: ChatDone = try await writes.perform(.chatDraftClear) {
                            ChatDraftClearRequest(requestID: $0, surfaceKey: key)
                        }
                    }
                } catch {
                    succeeded = false
                    NSLog("DatabaseDraftMirror: writing a queued draft failed: %@", error.localizedDescription)
                }
            }
            completion?(succeeded)
        }
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
