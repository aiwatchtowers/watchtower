import Foundation
import GRDB
import WatchtowerCore

// MARK: - SituationChatViewModel

/// Drives the "Discuss with secretary" chat inside the situation review pane.
/// A de-actioned mirror of `TargetChatViewModel`: persisted conversation per
/// situation (`chat_conversations.context_type = "situation"`), streaming via
/// `AIServiceProtocol`, no watchtower-action blocks. Its specialty is the
/// system prompt: situation context + member signals + the owner's secretary
/// brief, communication style profile, counterparty People-card briefs, and a
/// register sample of the owner's own messages in the situation's channels —
/// so a requested draft comes out in the owner's voice.
@MainActor
@Observable
final class SituationChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    /// Stable identity for a dictation targetID.
    var situationID: Int { situation.id }

    private var conversationID: Int64?
    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private let situation: Situation
    private let memberSignals: [InboxItem]
    private let selectedModel: ChatModel
    private var streamTask: Task<Void, Never>?

    init(
        situation: Situation,
        memberSignals: [InboxItem],
        dbManager: DatabaseManager,
        aiService: (any AIServiceProtocol)? = nil,
        provider: AIProvider? = nil
    ) {
        self.situation = situation
        self.memberSignals = memberSignals
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()
        let resolvedProvider = provider
            ?? (ConfigService().aiProvider == "codex" ? .codex : .claude)
        self.selectedModel = ChatModel.defaultModel(for: resolvedProvider)

        loadOrCreateConversation()
    }

    /// Message count of the persisted conversation for a situation — cheap
    /// badge read for the collapsed Discuss header; 0 when no conversation.
    static func persistedMessageCount(_ db: Database, situationID: Int) throws -> Int {
        guard let conv = try ChatConversationQueries.fetchByContext(
            db, type: "situation", id: String(situationID)
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
                    db, type: "situation", id: String(situation.id)
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
                    title: "Situation: \(String(situation.title.prefix(60)))",
                    contextType: "situation",
                    contextID: String(situation.id)
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

    /// `situation`/`memberSignals`/`aiService`/`dbManager` are all `let`
    /// constants set once in `init`, so they are read straight off `self`
    /// here rather than threaded through as parameters (this method already
    /// runs on the VM's actor). Only `currentSessionID`/`conversationID` are
    /// captured snapshots from the moment the turn was kicked off.
    private func executeStream(
        text: String,
        currentSessionID: String?,
        conversationID: Int64?
    ) async {
        let dbPool = dbManager.dbPool
        let systemPrompt: String? = currentSessionID == nil
            ? Self.buildSystemPrompt(situation: situation, memberSignals: memberSignals, dbPool: dbPool)
            : nil
        // Resumed sessions drop the system prompt (CLI --resume); carry the
        // situation context with the message so an expired session never loses
        // track of what is being discussed (same rationale as TargetChat).
        let effectivePrompt = currentSessionID == nil
            ? text
            : "\(Self.situationContextBlock(situation, memberSignals: memberSignals))\n\n\(text)"

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
            print("SituationChat: failed to persist session id: \(error)")
        }
    }

    private func persistMessage(conversationID: Int64, role: String, text: String) {
        do {
            try dbManager.dbPool.write { db in
                _ = try ChatMessageQueries.insert(db, conversationID: conversationID, role: role, text: text)
            }
        } catch {
            print("SituationChat: failed to persist \(role) message: \(error)")
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
            print("SituationChat: failed to persist assistant response: \(error)")
        }
    }

    // MARK: - System prompt

    /// The `=== SITUATION ===` block: card + member-signal originals. Also
    /// carried with the message on resumed sessions.
    nonisolated static func situationContextBlock(
        _ situation: Situation, memberSignals: [InboxItem]
    ) -> String {
        var b = """
        === SITUATION ===
        Title: \(situation.title)
        Kind: \(situation.kindRaw)  Priority: \(situation.priority)
        """
        if !situation.whyMatters.isEmpty { b += "\nWhy it matters: \(situation.whyMatters)" }
        if !situation.summary.isEmpty { b += "\nSummary: \(situation.summary)" }
        if !situation.chronology.isEmpty { b += "\nChronology:\n\(situation.chronology)" }
        if let targetID = situation.targetID { b += "\nLinked target id: \(targetID)" }
        if let trackID = situation.trackID { b += "\nLinked track id: \(trackID)" }
        b += "\n\n=== MEMBER SIGNALS (the underlying Slack messages, oldest first) ==="
        if memberSignals.isEmpty {
            b += "\n(none recorded)"
        }
        for item in memberSignals {
            b += "\n- [\(item.senderUserID) in \(item.channelID) at \(item.messageTS)] \(item.snippet)"
        }
        return b
    }

    /// `memoryChatEnabled` / `memoryVaultDir` default to the config-derived
    /// values in production; tests inject them explicitly. When the memory
    /// surface is off, the returned prompt is byte-identical to the pre-Phase-4
    /// output — the MEMORY section and memory-tool bullet are interpolated as
    /// empty-string slots on the disabled path, so no memory read runs and the
    /// base template is unchanged.
    nonisolated static func buildSystemPrompt(
        situation: Situation,
        memberSignals: [InboxItem],
        dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir()
    ) -> String {
        // current_user_id moved from workspace to slack_accounts (migration
        // 00048); pinned to account #1, mirroring Go's db.GetCurrentUserID.
        let ownerID = (try? dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT current_user_id FROM slack_accounts WHERE id = 1")
        } ?? "") ?? ""

        let brief = (try? dbPool.read { db in try SecretaryProfileQueries.fetch(db) }) ?? ""
        let style = (try? dbPool.read { db in try SecretaryProfileQueries.fetchStyle(db).text }) ?? ""

        let styleBlock = style.isEmpty
            ? "No stored style profile — mirror the owner's own messages in the register sample below."
            : "=== OWNER'S COMMUNICATION STYLE ===\n\(style)"

        // Phase-4 memory surface: the MEMORY block and the memory-tools bullet are
        // interpolated as neighbor-style slots — each an empty string when the
        // surface is off, so the disabled path is byte-identical to the pre-Phase-4
        // output (no splicing, no memory reads on the off path). See
        // SituationChatMemoryPromptTests.testDisabledPathByteIdenticalRegardlessOfMemoryData.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: situationSubjects(memberSignals: memberSignals), dbPool: dbPool)
              ) + "\n\n"
            : ""
        let memoryToolsBullet = memoryChatEnabled
            ? "- memory_recall / memory_open / memory_map — the secretary's built-up memory of "
                + "people, topics, and what it currently believes; check what the secretary already knows before "
                + "asking the user.\n"
            : ""

        let base = """
        You are the user's AI secretary, discussing ONE situation from their work dashboard. \
        Help them think it through; when they tell you WHAT to reply, turn their intent into the reply FOR them.

        DRAFT CONTRACT (strict): when the user states what to reply (their intent — e.g. "tell them we'll \
        roll back tomorrow"), produce ready-to-send Slack text in the OWNER'S voice — same language the \
        thread uses, same register the owner uses with these people — preserving the user's meaning and \
        adding NO commitments, facts, or content they didn't state. \
        No meta-commentary, no "here's a draft:", no signatures or pleasantries the owner wouldn't type. \
        Output the draft as a plain block the owner can copy verbatim; put any commentary AFTER the draft, clearly separated. \
        If the user has NOT said what to reply, discuss and advise — never push an unsolicited draft.

        \(situationContextBlock(situation, memberSignals: memberSignals))

        === WHO THE OWNER IS ===
        \(brief.isEmpty ? "(no brief provided)" : brief)

        \(styleBlock)

        \(counterpartyBlock(memberSignals: memberSignals, ownerID: ownerID, dbPool: dbPool))
        \(registerSampleBlock(memberSignals: memberSignals, ownerID: ownerID, dbPool: dbPool))
        \(memoryBlock)=== TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        You have read-only tools over the user's OWN local Watchtower database. \
        Use them to look things up instead of asking the user:
        - list_messages — search/list the user's Slack messages by person, channel, and/or keyword. \
        This is how you find what someone said (e.g. the open questions a colleague handed over). \
        Pass the person's name in `person` and optional keywords in `query`.
        \(memoryToolsBullet)- get_person / list_people — people cards; get_target / list_tracks / list_digests / list_jira_issues — work context.
        Never ask for a database path, never ask the user to authorize Slack, and never use claude.ai connectors \
        (the Slack connector or any other) — the data is already local and these tools are already connected. \
        If a lookup returns nothing, say so plainly rather than blaming access.

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        """

        return base
    }

    // MARK: - Memory surface (Phase 4, behind memory.surfaces.chat)

    /// Discuss's subjects: the situation's member signals' channel and sender
    /// user ids — unchanged from the pre-Slice-C relevantMemory's alias-key
    /// computation.
    nonisolated private static func situationSubjects(memberSignals: [InboxItem]) -> [String] {
        var subjects = Set<String>()
        for signal in memberSignals {
            if !signal.channelID.isEmpty { subjects.insert(signal.channelID) }
            if !signal.senderUserID.isEmpty { subjects.insert(signal.senderUserID) }
        }
        return Array(subjects)
    }

    /// People-card briefs for each distinct non-owner sender among the member
    /// signals. Empty string when nothing is available.
    nonisolated private static func counterpartyBlock(
        memberSignals: [InboxItem], ownerID: String, dbPool: DatabasePool
    ) -> String {
        let senderIDs = Array(Set(memberSignals.map(\.senderUserID)))
            .filter { !$0.isEmpty && $0 != ownerID }
            .sorted()
        guard !senderIDs.isEmpty else { return "" }
        var sections: [String] = []
        for senderID in senderIDs {
            guard let card = try? dbPool.read({ db in
                try PeopleCardQueries.fetchByUser(db, userID: senderID, limit: 1).first
            })
            else { continue }
            var lines: [String] = []
            if !card.communicationStyle.isEmpty { lines.append("Their style: \(card.communicationStyle)") }
            if !card.communicationGuide.isEmpty { lines.append("How to talk to them: \(card.communicationGuide)") }
            if !card.relationshipContext.isEmpty { lines.append("Relationship: \(card.relationshipContext)") }
            if !lines.isEmpty {
                sections.append("[\(senderID)]\n" + lines.joined(separator: "\n"))
            }
        }
        guard !sections.isEmpty else { return "" }
        return """
        === COUNTERPARTIES (from prior AI analysis) ===
        \(sections.joined(separator: "\n\n"))

        """
    }

    /// The owner's last messages in each of the situation's channels — the
    /// concrete voice to imitate with this audience. Empty string when none.
    nonisolated private static func registerSampleBlock(
        memberSignals: [InboxItem], ownerID: String, dbPool: DatabasePool
    ) -> String {
        guard !ownerID.isEmpty else { return "" }
        let channelIDs = Array(Set(memberSignals.map(\.channelID))).filter { !$0.isEmpty }.sorted()
        guard !channelIDs.isEmpty else { return "" }
        var lines: [String] = []
        for channelID in channelIDs {
            let texts = (try? dbPool.read { db in
                try String.fetchAll(db, sql: """
                    SELECT text FROM messages
                    WHERE channel_id = ? AND user_id = ? AND is_deleted = 0 AND subtype = ''
                      AND LENGTH(TRIM(text)) >= 8
                    ORDER BY ts_unix DESC LIMIT 10
                    """, arguments: [channelID, ownerID])
            }) ?? []
            for text in texts {
                lines.append("- [\(channelID)] \(text.split(whereSeparator: \.isNewline).joined(separator: " "))")
            }
        }
        guard !lines.isEmpty else { return "" }
        return """
        === REGISTER SAMPLE (the owner's own recent messages in these channels — imitate this voice) ===
        \(lines.joined(separator: "\n"))

        """
    }
}
