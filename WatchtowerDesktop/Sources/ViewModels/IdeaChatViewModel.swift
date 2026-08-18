import Foundation
import GRDB
import WatchtowerCore

// MARK: - IdeaChatViewModel

/// Drives the "Discuss with secretary" chat inside the idea detail pane. The
/// deliberate house-pattern copy of `SituationChatViewModel` for ideas
/// (`chat_conversations.context_type = "idea"`), streaming via
/// `AIServiceProtocol`. Kept lean relative to the situation VM: no member
/// signals, no counterparty/register-sample/memory blocks — the idea's own
/// context (kind/status/title/essence/mentions) plus the owner's secretary
/// brief and style are enough for a discussion about one registry entry.
@MainActor
@Observable
final class IdeaChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    /// Stable identity for a dictation targetID.
    var ideaID: Int { idea.id }

    private var conversationID: Int64?
    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private let idea: Idea
    private let mentions: [IdeaMention]
    private let selectedModel: ChatModel
    private var streamTask: Task<Void, Never>?

    init(
        idea: Idea,
        mentions: [IdeaMention],
        dbManager: DatabaseManager,
        aiService: (any AIServiceProtocol)? = nil,
        provider: AIProvider? = nil
    ) {
        self.idea = idea
        self.mentions = mentions
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()
        let resolvedProvider = provider
            ?? (ConfigService().aiProvider == "codex" ? .codex : .claude)
        self.selectedModel = ChatModel.defaultModel(for: resolvedProvider)

        loadOrCreateConversation()
    }

    /// Message count of the persisted conversation for an idea — cheap badge
    /// read for the collapsed Discuss header; 0 when no conversation.
    static func persistedMessageCount(_ db: Database, ideaID: Int) throws -> Int {
        guard let conv = try ChatConversationQueries.fetchByContext(
            db, type: "idea", id: String(ideaID)
        ) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?",
            arguments: [conv.id]
        ) ?? 0
    }

    private func loadOrCreateConversation() {
        do {
            if let existing = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByContext(
                    db, type: "idea", id: String(idea.id)
                )
            }) {
                let records = try dbManager.dbPool.read { db in
                    try ChatMessageQueries.fetchByConversation(db, conversationID: existing.id)
                }
                conversationID = existing.id
                sessionID = existing.sessionID
                messages = records.map { $0.toChatMessage() }
                return
            }
            let conv = try dbManager.dbPool.write { db in
                try ChatConversationQueries.create(
                    db,
                    title: "Idea: \(String(idea.title.prefix(60)))",
                    contextType: "idea",
                    contextID: String(idea.id)
                )
            }
            conversationID = conv.id
            sessionID = conv.sessionID
            messages = []
        } catch {
            errorMessage = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

    // MARK: - Sending

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        inputText = ""
        sendUserMessage(text)
    }

    private func sendUserMessage(_ text: String) {
        streamTask?.cancel()
        messages.append(ChatMessage(
            id: UUID(), role: .user, text: text, timestamp: Date(), isStreaming: false
        ))
        if let convID = conversationID {
            persistMessage(conversationID: convID, role: "user", text: text)
        }
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))

        isStreaming = true
        let currentSessionID = sessionID
        let capturedConvID = conversationID

        streamTask = Task { [weak self] in
            await self?.executeStream(
                text: text, currentSessionID: currentSessionID, conversationID: capturedConvID
            )
        }
    }

    // MARK: - Stream execution

    /// `idea`/`mentions`/`aiService`/`dbManager` are all `let` constants set
    /// once in `init`, so they are read straight off `self` here rather than
    /// threaded through as parameters (this method already runs on the VM's
    /// actor). Only `currentSessionID`/`conversationID` are captured
    /// snapshots from the moment the turn was kicked off.
    private func executeStream(
        text: String,
        currentSessionID: String?,
        conversationID: Int64?
    ) async {
        let dbPool = dbManager.dbPool
        let systemPrompt: String? = currentSessionID == nil
            ? Self.buildSystemPrompt(idea: idea, mentions: mentions, dbPool: dbPool)
            : nil
        // Resumed sessions drop the system prompt (CLI --resume); carry the
        // idea context with the message so an expired session never loses
        // track of what is being discussed (same rationale as SituationChat).
        let effectivePrompt = currentSessionID == nil
            ? text
            : "\(Self.ideaContextBlock(idea, mentions: mentions))\n\n\(text)"

        var fullText = ""
        do {
            let stream = aiService.stream(
                prompt: effectivePrompt,
                systemPrompt: systemPrompt,
                sessionID: currentSessionID,
                dbPath: dbPool.path,
                model: selectedModel.rawValue
            )
            var sawTurnComplete = false
            for try await event in stream {
                switch event {
                case .text(let chunk):
                    if sawTurnComplete {
                        fullText = chunk
                        sawTurnComplete = false
                    } else {
                        fullText += chunk
                    }
                    updateLastMessage(fullText)
                case .turnComplete(let text):
                    fullText = text
                    sawTurnComplete = true
                    updateLastMessage(fullText)
                case .sessionID(let sid):
                    handleSessionID(sid)
                case .done:
                    break
                }
            }
            if !fullText.isEmpty, let convID = conversationID {
                Self.persistResponse(dbManager: dbManager, conversationID: convID, text: fullText)
            }
        } catch {
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }
        finishStream()
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let idx = messages.indices.last, messages[idx].isStreaming {
            let partial = messages[idx].text
            if !partial.isEmpty, let convID = conversationID {
                persistMessage(conversationID: convID, role: "assistant", text: partial)
            }
            messages[idx].isStreaming = false
        }
    }

    // MARK: - Persistence / state helpers

    private func updateLastMessage(_ text: String) {
        if let idx = messages.indices.last {
            messages[idx].text = text
        }
    }

    private func finishStream() {
        for idx in messages.indices where messages[idx].isStreaming {
            messages[idx].isStreaming = false
        }
        isStreaming = false
    }

    private func handleSessionID(_ sid: String) {
        sessionID = sid
        guard let convID = conversationID else { return }
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.updateSessionID(db, id: convID, sessionID: sid)
            }
        } catch {
            print("IdeaChat: failed to persist session id: \(error)")
        }
    }

    private func persistMessage(conversationID: Int64, role: String, text: String) {
        do {
            try dbManager.dbPool.write { db in
                _ = try ChatMessageQueries.insert(db, conversationID: conversationID, role: role, text: text)
            }
        } catch {
            print("IdeaChat: failed to persist \(role) message: \(error)")
        }
    }

    nonisolated private static func persistResponse(
        dbManager: DatabaseManager, conversationID: Int64, text: String
    ) {
        do {
            try dbManager.dbPool.write { db in
                try ChatMessageQueries.insert(db, conversationID: conversationID, role: "assistant", text: text)
                try ChatConversationQueries.touch(db, id: conversationID)
            }
        } catch {
            print("IdeaChat: failed to persist assistant response: \(error)")
        }
    }

    // MARK: - System prompt

    /// The `=== IDEA ===` block: kind/status/title/essence, plus a
    /// `=== MENTIONS ===` chronology. Also carried with the message on
    /// resumed sessions.
    nonisolated static func ideaContextBlock(_ idea: Idea, mentions: [IdeaMention]) -> String {
        var b = """
        === IDEA ===
        Kind: \(idea.kindRaw)  Status: \(idea.statusRaw)
        Title: \(idea.title)
        """
        if !idea.essence.isEmpty { b += "\nEssence: \(idea.essence)" }
        b += "\n\n=== MENTIONS ==="
        if mentions.isEmpty {
            b += "\n(none recorded)"
        }
        for mention in mentions {
            let author = mention.author.isEmpty ? mention.sourceKind.rawValue : mention.author
            b += "\n- [\(author) at \(mention.saidAt)] \(mention.quote) (ref: \(mention.ref))"
        }
        return b
    }

    nonisolated static func buildSystemPrompt(
        idea: Idea,
        mentions: [IdeaMention],
        dbPool: DatabasePool
    ) -> String {
        let brief = (try? dbPool.read { db in try SecretaryProfileQueries.fetch(db) }) ?? ""
        let style = (try? dbPool.read { db in try SecretaryProfileQueries.fetchStyle(db).text }) ?? ""
        let styleBlock = style.isEmpty ? "" : "\n\n=== OWNER'S COMMUNICATION STYLE ===\n\(style)"

        return """
        You are the user's AI secretary, discussing ONE entry from their Ideas & Decisions registry \
        (an idea, decision, or note). Help them think it through — clarify the reasoning, surface risks, \
        or expand on it as asked.

        \(ideaContextBlock(idea, mentions: mentions))

        === WHO THE OWNER IS ===
        \(brief.isEmpty ? "(no brief provided)" : brief)\(styleBlock)

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        You have read-only tools over the user's OWN local Watchtower database. \
        Use them to look things up instead of asking the user:
        - list_ideas / get_idea — the ideas/decisions/notes registry, including every mention across sources.
        - list_messages — search/list the user's Slack messages by person, channel, and/or keyword.
        - get_person / list_people — people cards; get_target / list_tracks / list_digests / list_jira_issues — work context.
        Never ask for a database path, never ask the user to authorize Slack, and never use claude.ai connectors \
        (the Slack connector or any other) — the data is already local and these tools are already connected. \
        If a lookup returns nothing, say so plainly rather than blaming access.
        \(ChatViewModel.noLiveSourcesRule)

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        """
    }
}
