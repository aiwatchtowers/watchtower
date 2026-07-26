import Foundation
import GRDB

/// Secretary chat about ONE meeting recording. Persisted conversation per
/// transcript (`chat_conversations.context_type = "meeting"`), streaming via
/// `AIServiceProtocol` — same skeleton as SituationChatViewModel, but the
/// context is the transcript + recap, and the full transcript text is
/// reachable via the get_transcript MCP tool instead of being inlined
/// wholesale (hour-long transcripts would blow the interactive CLI's ARG_MAX).
@MainActor
@Observable
final class MeetingChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?

    private var conversationID: Int64?
    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private let transcript: MeetingTranscript
    private let recapContent: MeetingRecap.Content?
    private let selectedModel: ChatModel
    private var streamTask: Task<Void, Never>?

    /// Characters of transcript inlined into the system prompt; the rest is
    /// fetched by the model on demand via get_transcript.
    static let transcriptExcerptLimit = 12_000

    init(
        transcript: MeetingTranscript,
        recapContent: MeetingRecap.Content?,
        dbManager: DatabaseManager,
        aiService: (any AIServiceProtocol)? = nil,
        provider: AIProvider? = nil
    ) {
        self.transcript = transcript
        self.recapContent = recapContent
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()
        let resolvedProvider = provider
            ?? (ConfigService().aiProvider == "codex" ? .codex : .claude)
        self.selectedModel = ChatModel.defaultModel(for: resolvedProvider)

        loadOrCreateConversation()
    }

    /// Message count of the persisted conversation for a transcript — cheap
    /// badge read for a collapsed Discuss header; 0 when no conversation.
    static func persistedMessageCount(_ db: Database, transcriptID: Int64) throws -> Int {
        guard let conv = try ChatConversationQueries.fetchByContext(
            db, type: "meeting", id: String(transcriptID)
        ) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?",
            arguments: [conv.id]
        ) ?? 0
    }

    private func loadOrCreateConversation() {
        guard let id = transcript.id else { return }
        do {
            if let existing = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByContext(db, type: "meeting", id: String(id))
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
                    title: "Meeting: \(String(transcript.title.prefix(60)))",
                    contextType: "meeting",
                    contextID: String(id)
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

    /// `transcript`/`recapContent`/`aiService`/`dbManager` are all `let`
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
            ? Self.buildSystemPrompt(transcript: transcript, recapContent: recapContent, dbPool: dbPool)
            : nil
        // Resumed sessions drop the system prompt (CLI --resume); carry the
        // meeting context with the message so an expired session never loses
        // track of what is being discussed (same rationale as SituationChat).
        let effectivePrompt = currentSessionID == nil
            ? text
            : "\(Self.meetingContextBlock(transcript, recapContent: recapContent))\n\n\(text)"

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
            print("MeetingChat: failed to persist session id: \(error)")
        }
    }

    private func persistMessage(conversationID: Int64, role: String, text: String) {
        do {
            try dbManager.dbPool.write { db in
                _ = try ChatMessageQueries.insert(db, conversationID: conversationID, role: role, text: text)
            }
        } catch {
            print("MeetingChat: failed to persist \(role) message: \(error)")
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
            print("MeetingChat: failed to persist assistant response: \(error)")
        }
    }

    // MARK: - System prompt

    /// The `=== MEETING RECORDING ===` block: transcript metadata + recap.
    /// Also carried with the message on resumed sessions.
    nonisolated static func meetingContextBlock(
        _ transcript: MeetingTranscript, recapContent: MeetingRecap.Content?
    ) -> String {
        var b = """
        === MEETING RECORDING ===
        Title: \(transcript.title)
        Recorded: \(transcript.createdAt)  Duration: \(transcript.durationSec)s
        Transcript id: \(transcript.id.map(String.init) ?? "?") (fetch the FULL text with the get_transcript tool)
        """
        if let recap = recapContent {
            if !recap.summary.isEmpty { b += "\nRecap summary: \(recap.summary)" }
            if !recap.keyDecisions.isEmpty { b += "\nDecisions:\n- " + recap.keyDecisions.joined(separator: "\n- ") }
            if !recap.actionItems.isEmpty { b += "\nAction items:\n- " + recap.actionItems.joined(separator: "\n- ") }
            if !recap.openQuestions.isEmpty { b += "\nOpen questions:\n- " + recap.openQuestions.joined(separator: "\n- ") }
        }
        return b
    }

    /// This meeting's subjects for the MEMORY block: the linked calendar
    /// event's attendees (Slack user id where already resolved via
    /// calendar_attendee_map, plus email always). An ad-hoc recording with no
    /// linked event (eventID == nil) or a since-deleted event yields an empty,
    /// clean subject list — not an error.
    nonisolated static func meetingMemorySubjects(transcript: MeetingTranscript, dbPool: DatabasePool) -> [String] {
        guard let eventID = transcript.eventID else { return [] }
        let event = try? dbPool.read { db in
            try CalendarEvent.fetchOne(db, sql: "SELECT * FROM calendar_events WHERE id = ?", arguments: [eventID])
        }
        guard let event = event else { return [] }
        var subjects = Set<String>()
        for attendee in event.parsedAttendees {
            if !attendee.slackUserID.isEmpty { subjects.insert(attendee.slackUserID) }
            if !attendee.email.isEmpty { subjects.insert(attendee.email) }
        }
        return Array(subjects)
    }

    nonisolated static func buildSystemPrompt(
        transcript: MeetingTranscript,
        recapContent: MeetingRecap.Content?,
        dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir()
    ) -> String {
        let excerpt = String(transcript.transcriptText.prefix(transcriptExcerptLimit))
        let truncated = transcript.transcriptText.count > transcriptExcerptLimit

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — same pattern as
        // SituationChatViewModel/TrackChatViewModel/TargetChatViewModel.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: meetingMemorySubjects(transcript: transcript, dbPool: dbPool), dbPool: dbPool)
              ) + "\n\n"
            : ""

        return """
        You are the user's AI secretary, discussing ONE recorded meeting. \
        Help them recall what was said, clarify decisions, and draft follow-ups when asked.

        \(meetingContextBlock(transcript, recapContent: recapContent))

        \(memoryBlock)=== TRANSCRIPT EXCERPT (single-track, speakers not labeled, may mix ru/uk/en) ===
        \(excerpt)
        \(truncated ? "(…truncated — use get_transcript with the transcript id above for the full text)" : "(full transcript shown)")

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        - get_transcript / list_transcripts — the full transcript text of this and other recordings.
        - list_messages, get_person / list_people, get_target / list_tracks — surrounding work context.
        Never ask for a database path; the data is already local and the tools are already connected.

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        - Quote the transcript verbatim when the user asks "what exactly was said".
        """
    }
}
