import Foundation
import GRDB

/// The writes a running turn makes. Swift is the only writer of these rows
/// (spec §2.2); every write is synchronous and small.
package struct ChatTurnStore: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    package func saveProgress(messageID: Int64, text: String, status: String, usage: ChatUsage?, errorCode: String?) throws {
        try dbPool.write { db in
            try ChatTreeQueries.updateAssistant(db, id: messageID, text: text, status: status,
                                                tokensIn: usage?.tokensIn, tokensOut: usage?.tokensOut,
                                                errorCode: errorCode, errorMessage: nil)
            if let model = usage?.model, !model.isEmpty {
                try ChatTreeQueries.setModel(db, messageID: messageID, model: model)
            }
        }
    }

    package func stepStarted(messageID: Int64, seq: Int, start: ChatToolStart, at date: Date) throws {
        try dbPool.write { db in
            try ChatStepQueries.upsertStart(db, messageID: messageID, seq: seq, toolID: start.id, name: start.name,
                                            argsJSON: start.argsJSON, startedAt: date.timeIntervalSince1970)
        }
    }

    package func stepFinished(messageID: Int64, end: ChatToolEnd, at date: Date) throws {
        try dbPool.write { db in
            try ChatStepQueries.finish(db, messageID: messageID, toolID: end.id, ok: end.ok, summary: end.summary,
                                       sourcesJSON: ChatSource.encodeList(end.sources), endedAt: date.timeIntervalSince1970)
        }
    }

    /// A session spawned for another project than the conversation's current
    /// one (the chat was moved mid-turn) records nothing: resuming it would
    /// skip the new project's prompt and files.
    package func saveSessionID(conversationID: Int64, sessionID: String, projectID: Int64?) throws {
        try dbPool.write { db in
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
    @discardableResult
    package func finalizeTurn(
        conversationID: Int64, messageID: Int64, text: String, status: String, usage: ChatUsage?,
        error: ChatSessionError?
    ) throws -> [ChatArtifact] {
        try dbPool.write { db in
            try ChatTreeQueries.updateAssistant(db, id: messageID, text: text, status: status,
                                                tokensIn: usage?.tokensIn, tokensOut: usage?.tokensOut,
                                                errorCode: error?.code.rawValue, errorMessage: error?.message)
            if let model = usage?.model, !model.isEmpty {
                try ChatTreeQueries.setModel(db, messageID: messageID, model: model)
            }
            guard status != "error" else { return [] }
            return try ChatArtifactQueries.persistArtifacts(db, conversationID: conversationID, messageID: messageID, text: text)
        }
    }
}
