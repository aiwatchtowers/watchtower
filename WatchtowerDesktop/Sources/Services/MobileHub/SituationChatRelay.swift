import Foundation
import GRDB

/// Resolves a mobile chat turn that carries a `situation` context into the
/// DESKTOP's own Discuss conversation for that situation, so both surfaces
/// share one thread (`chat_conversations.context_type = "situation"`).
///
/// Why one thread and not a mobile-only mirror: the desktop's Discuss pane
/// then shows phone-authored turns, and the Phase-4 memory chat ingest — which
/// stages `role='user'` situation turns as owner-rank belief evidence — picks
/// them up with no memory-side change (see MEM-09, `chat_ingest.go`).
///
/// v1 asymmetry, deliberate: turns flow phone → desktop only. The phone renders
/// the turns it authored (its own replica rows); desktop-authored turns are not
/// synced down, which would need a chat_message slice kind and a call on chat
/// text in DataZone.
///
/// The prompt is built by the desktop's own `SituationChatViewModel` statics —
/// the same system prompt, draft contract, and resumed-session context block
/// the Mac uses — so an answer does not depend on which device asked.
enum SituationChatRelay {
    /// Everything `RelayProcessor` needs to stream one situation turn: which
    /// CLI session to resume (nil on the thread's first ever turn, when the
    /// full system prompt applies instead) and what text to send.
    struct Turn {
        let conversationID: Int64
        let cliSessionID: String?
        let systemPrompt: String?
        /// The user's text, prefixed with the situation context block when a
        /// session is being resumed (`SituationChatViewModel`'s rule: an
        /// expired CLI session must never lose track of the subject).
        let promptText: String
    }

    /// Resolves the conversation, persists the user turn, and builds the
    /// prompt.
    ///
    /// Two phases on purpose: the conversation resolve + user-turn insert run
    /// in ONE write (a turn that reaches the model is always recorded on the
    /// desktop side too), while the prompt is built afterwards — it reads
    /// people cards, the style profile and raw messages through the pool, and
    /// a nested read inside the write would trap on DatabasePool reentrancy.
    ///
    /// The CLI session id comes from the CONVERSATION ROW, not the sidecar's
    /// mobile-session map: this thread belongs to the desktop, which may have
    /// advanced (or minted) the session since the phone last wrote. The
    /// sidecar map stays the generic chat's business.
    static func prepareTurn(
        dbPool: DatabasePool,
        situationID: Int,
        text: String
    ) throws -> Turn {
        let resolved = try dbPool.write { db -> (Situation, [InboxItem], ChatConversation) in
            guard let situation = try SituationQueries.fetchByID(db, id: situationID) else {
                throw SituationChatRelayError.situationNotFound(situationID)
            }
            let signals = try SituationQueries.memberSignals(db, situationID: situationID)

            try ChatConversationQueries.ensureTable(db)
            try ChatMessageQueries.ensureTable(db)
            let conversation = try ChatConversationQueries.fetchByContext(
                db, type: "situation", id: String(situationID)
            ) ?? ChatConversationQueries.create(
                db,
                // The desktop's own title format, so a conversation minted from
                // the phone is indistinguishable from one minted in Discuss.
                title: "Situation: \(String(situation.title.prefix(60)))",
                contextType: "situation",
                contextID: String(situationID)
            )
            _ = try ChatMessageQueries.insert(
                db, conversationID: conversation.id, role: "user", text: text
            )
            return (situation, signals, conversation)
        }

        let (situation, signals, conversation) = resolved
        let sessionID = (conversation.sessionID?.isEmpty ?? true) ? nil : conversation.sessionID
        return Turn(
            conversationID: conversation.id,
            cliSessionID: sessionID,
            systemPrompt: sessionID == nil
                ? SituationChatViewModel.buildSystemPrompt(
                    situation: situation, memberSignals: signals, dbPool: dbPool
                  )
                : nil,
            promptText: sessionID == nil
                ? text
                : "\(SituationChatViewModel.situationContextBlock(situation, memberSignals: signals))\n\n\(text)"
        )
    }

    /// Records the completed answer on the desktop side and bumps the
    /// conversation. Called only for a SUCCESSFUL turn: an aborted stream's
    /// partial text and the "⚠️ …" error chunk stay on the phone rather than
    /// entering the shared thread (the desktop's Discuss pane would otherwise
    /// show a failure it cannot retry). The user turn is already persisted
    /// either way — that is the half the memory ingest reads.
    static func persistAnswer(dbPool: DatabasePool, conversationID: Int64, text: String) throws {
        guard !text.isEmpty else { return }
        try dbPool.write { db in
            _ = try ChatMessageQueries.insert(
                db, conversationID: conversationID, role: "assistant", text: text
            )
            try ChatConversationQueries.touch(db, id: conversationID)
        }
    }

    /// Persists the CLI session id the stream reported, so the next turn —
    /// from either device — resumes the same session.
    static func persistSessionID(dbPool: DatabasePool, conversationID: Int64, sessionID: String) throws {
        try dbPool.write { db in
            try ChatConversationQueries.updateSessionID(db, id: conversationID, sessionID: sessionID)
        }
    }
}

/// Why a situation turn could not be prepared. `errorDescription` becomes the
/// final chunk's text echoed back to the phone.
enum SituationChatRelayError: Error, LocalizedError, Equatable {
    case situationNotFound(Int)
    /// A context type this desktop does not know how to answer (a newer phone
    /// build). Answering it as the generic chat would silently drop the
    /// context the user asked about.
    case unsupportedContext(String)

    var errorDescription: String? {
        switch self {
        case .situationNotFound:
            return "this situation is no longer open"
        case .unsupportedContext(let type):
            return "this chat needs a newer desktop app (unknown context: \(type))"
        }
    }
}
