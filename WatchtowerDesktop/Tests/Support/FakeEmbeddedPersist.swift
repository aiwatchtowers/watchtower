import Foundation
import GRDB
import WatchtowerCore

/// What `ai query --persist` writes for an embedded chat's turn
/// (`chatstore.EmbeddedTurn`), for `ScriptedAIService`: the owner row and the
/// reply's empty `partial` row, the reply's text, steps, actual provider and
/// usage as they come, and its end — `complete` when the run ends cleanly, the
/// turn's error, or `partial` when it ends otherwise. Runs on `queue`.
package final class FakeEmbeddedPersist: @unchecked Sendable {
    package let queue = DispatchQueue(label: "FakeEmbeddedPersist")
    /// Let go once the turn ended (a test run keeps every fake alive).
    private var db: (any DatabaseWriter)?
    private let persist: ChatQueryPersist
    private let provider: String?
    private var messageID: Int64 = 0
    private var reducer = EmbeddedStreamReducer()
    private var steps: [String] = []
    private var usage: ChatUsage?
    private var done = false

    init?(dbPath: String, persist: ChatQueryPersist, provider: String?) {
        var config = Configuration()
        config.busyMode = .timeout(30)
        config.prepareDatabase { try $0.execute(sql: "PRAGMA foreign_keys = ON") }
        guard let db = TestDatabasePools.pool(at: dbPath) ?? (try? DatabasePool(path: dbPath, configuration: config))
        else { return nil }
        self.db = db
        self.persist = persist
        self.provider = provider
    }

    /// The turn's starting rows; its `.started`.
    func begin() throws -> StreamEvent {
        let (persist, provider) = (persist, provider)
        guard let db else { throw ChatContextGoneError() }
        let ids = try db.write { db in
            try ChatMessageQueries.beginEmbeddedTurn(db, conversationID: persist.conversationID,
                                                     ownerText: persist.ownerText, turnID: persist.turnID,
                                                     provider: provider, now: Date().timeIntervalSince1970)
        }
        messageID = ids.assistantID
        return .started(ownerID: ids.ownerID, assistantID: ids.assistantID)
    }

    func apply(_ event: StreamEvent) {
        guard !done, messageID != 0 else { return }
        let id = messageID
        switch event {
        case let .routing(provider, model, _):
            guard !provider.isEmpty else { return }
            try? db?.write { db in
                try db.execute(sql: "UPDATE chat_messages SET provider = ?, model = ? WHERE id = ?",
                               arguments: [provider, model, id])
            }
        case let .toolStart(start):
            let seq = steps.firstIndex(of: start.id) ?? steps.count
            if !steps.contains(start.id) { steps.append(start.id) }
            try? db?.write { db in
                try ChatStepQueries.upsertStart(db, messageID: id, seq: seq, toolID: start.id, name: start.name,
                                                argsJSON: start.argsJSON, startedAt: Date().timeIntervalSince1970)
            }
        case let .toolEnd(end):
            try? db?.write { db in
                try ChatStepQueries.finish(db, messageID: id, toolID: end.id, ok: end.ok, summary: end.summary,
                                           sourcesJSON: ChatSource.encodeList(end.sources),
                                           endedAt: Date().timeIntervalSince1970)
            }
        case let .usage(value):
            usage = value
        case let .failure(error):
            finalize(status: error.persistenceCode == ChatErrorCode.quotaExhausted.rawValue && !reducer.text.isEmpty
                     ? "partial" : "error", error: error)
        default:
            if case let .text(text) = reducer.apply(event) {
                try? db?.write { db in try ChatMessageQueries.saveEmbeddedProgress(db, messageID: id, text: text) }
            }
        }
    }

    /// The run ended: cleanly (`complete`) or not (`partial`).
    func finish(failed: Bool) {
        finalize(status: failed ? "partial" : "complete", error: nil)
    }

    private func finalize(status: String, error: ChatSessionError?) {
        guard !done, messageID != 0 else { return }
        done = true
        let (id, text, usage, conversationID) = (messageID, reducer.text, usage, persist.conversationID)
        try? db?.write { db in
            if let usage { try ChatMessageQueries.saveEmbeddedUsage(db, messageID: id, usage: usage) }
            try ChatMessageQueries.finalizeEmbedded(db, messageID: id, text: text, status: status,
                                                    errorCode: error?.persistenceCode, errorMessage: error?.message)
            if status == "complete" { try ChatConversationQueries.touch(db, id: conversationID) }
        }
        db = nil
    }
}

extension FakeEmbeddedPersist {
    /// `stream` as an `ai query --persist` run: `.started` first (the rows
    /// written), each event folded into the reply as it passes, the end
    /// written when the run ends — for test doubles that script only the
    /// provider's events. Like Go, the provider is reached only once the
    /// starting rows are written: a failed start never sends the prompt.
    package static func wrap(
        _ makeStream: @escaping @Sendable () -> AsyncThrowingStream<StreamEvent, Error>, dbPath: String?, persist: ChatQueryPersist, provider: String?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let dbPath, let emulator = FakeEmbeddedPersist(dbPath: dbPath, persist: persist, provider: provider) else {
                continuation.finish(throwing: ChatWriteError(sentence: "--persist needs a database"))
                return
            }
            let task = Task {
                do {
                    continuation.yield(try emulator.begin())
                    for try await event in makeStream() {
                        emulator.apply(event)
                        continuation.yield(event)
                    }
                    // A run stopped (its consumer went away) ends `partial`.
                    emulator.finish(failed: Task.isCancelled)
                    continuation.finish()
                } catch {
                    emulator.finish(failed: true)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
