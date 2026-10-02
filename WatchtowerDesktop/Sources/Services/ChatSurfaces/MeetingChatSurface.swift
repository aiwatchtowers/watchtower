import Foundation
import GRDB
import WatchtowerCore

/// Assistant chat about ONE meeting recording
/// (`chat_conversations.context_type = "meeting"`), on the shared embedded
/// chat component. The context is the transcript + recap; the full
/// transcript text is reachable via the get_transcript MCP tool instead of
/// being inlined wholesale (hour-long transcripts would blow the interactive
/// CLI's ARG_MAX). A draft-only surface: the intent-draft contract applies
/// (review-rules "The assistant & chat contracts") — no tool mode.
enum MeetingChatSurface {
    static let contextType = "meeting"

    /// Characters of transcript inlined into the system prompt; the rest is
    /// fetched by the model on demand via get_transcript.
    static let transcriptExcerptLimit = 12_000

    static let starterPrompts = [
        ChatStarterPrompt(title: "What was decided?", text: "What was decided in this meeting?", sendsImmediately: true),
        ChatStarterPrompt(title: "List the action items", text: "List the action items with their owners.",
                          sendsImmediately: true),
        ChatStarterPrompt(title: "Draft a follow-up…", text: "Draft a follow-up message to ", sendsImmediately: false)
    ]

    /// The recording's conversation, created on first use.
    static func conversationID(transcriptID: Int64, title: String, dbPool: DatabasePool) throws -> Int64 {
        try DatabaseEmbeddedChatStore.conversationID(
            dbPool: dbPool, contextType: contextType, contextID: String(transcriptID),
            title: "Meeting: \(String(title.prefix(60)))")
    }

    /// Built per render from the latest transcript and recap, so an edited
    /// transcript reaches the next first-turn prompt without a new engine.
    static func spec(
        transcript: MeetingTranscript,
        transcriptID: Int64,
        recapContent: MeetingRecap.Content?,
        conversationID: Int64,
        dbPool: DatabasePool
    ) -> ChatSurfaceSpec {
        ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: String(transcriptID), conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            systemPrompt: { buildSystemPrompt(transcript: transcript, recapContent: recapContent, dbPool: dbPool) },
            // Resumed sessions drop the system prompt (CLI --resume); carry the
            // meeting context with the message so an expired session never
            // loses track of what is being discussed.
            turnPrompt: {
                $0.isResumed ? "\(meetingContextBlock(transcript, recapContent: recapContent))\n\n\($0.text)" : $0.text
            },
            emptyHint: "Ask about this meeting — what was decided, who said what, or draft a follow-up.",
            starterPrompts: starterPrompts
        )
    }

    // MARK: - System prompt

    /// The `=== MEETING RECORDING ===` block: transcript metadata + recap.
    /// Also carried with the message on resumed sessions.
    static func meetingContextBlock(
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
    static func meetingMemorySubjects(transcript: MeetingTranscript, dbPool: DatabasePool) -> [String] {
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

    static func buildSystemPrompt(
        transcript: MeetingTranscript,
        recapContent: MeetingRecap.Content?,
        dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir(),
        skillsDir: String? = SkillsCatalog.defaultDir()
    ) -> String {
        let excerpt = String(transcript.transcriptText.prefix(transcriptExcerptLimit))
        let truncated = transcript.transcriptText.count > transcriptExcerptLimit

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — same pattern as
        // TrackChatSurface/TargetChatViewModel.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: meetingMemorySubjects(transcript: transcript, dbPool: dbPool), dbPool: dbPool)
              ) + "\n\n"
            : ""

        // Assistant skills: whether this surface lists them comes from its
        // context_type via SkillsCatalog.chatContextTypes, and the block is
        // nil when no enabled skill matches, so a workspace with no skills
        // keeps a byte-identical prompt.
        let skillsSuffix = SkillsCatalog.promptBlock(contextType: contextType, dir: skillsDir)
            .map { "\n\n" + $0 } ?? ""

        return """
        You are the user's AI assistant, discussing ONE recorded meeting. \
        Help them recall what was said, clarify decisions, and draft follow-ups when asked.

        \(meetingContextBlock(transcript, recapContent: recapContent))

        \(memoryBlock)=== TRANSCRIPT EXCERPT (may mix ru/uk/en; a "[label]" line prefix identifies the speaker — \
        "[Я]" is the recording owner, "[Speaker N]" an unidentified voice, anything else a real name; \
        a line with no prefix carries no attribution) ===
        \(excerpt)
        \(truncated ? "(…truncated — use get_transcript with the transcript id above for the full text)" : "(full transcript shown)")

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        - search_knowledge / get_knowledge_document — relevance search across Slack, mail, Jira, Confluence, calendar, \
        transcripts, recaps, digests, decisions and ideas; open a hit in full by its ref. Pass 2-5 queries: \
        key terms, synonyms, Russian and English variants, stems ending in * for Russian word forms.
        - get_transcript / list_transcripts — the full transcript text of this and other recordings.
        - list_messages, get_person / list_people, get_target / list_tracks — surrounding work context.
        Never ask for a database path; the data is already local and the tools are already connected.
        \(ChatPromptRules.noLiveSourcesRule)

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        - Quote the transcript verbatim when the user asks "what exactly was said".
        """ + skillsSuffix + "\n\n" + ChatQuestionsContract.promptBlock
    }
}
