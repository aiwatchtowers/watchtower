import Foundation
import GRDB
import WatchtowerCore

// MARK: - IdeaChatSurface

/// The "Discuss with assistant" chat of one idea, decision or note
/// (`chat_conversations.context_type = "idea"`), on the shared embedded chat
/// component. A draft-only surface (review-rules "The assistant & chat
/// contracts"): no tool mode. Kept lean — no MEMORY block: the idea's own
/// context (kind/status/title/essence/mentions) plus the owner's assistant
/// brief and style are enough for a discussion about one registry entry.
enum IdeaChatSurface {
    static let contextType = "idea"

    static let starterPrompts = [
        ChatStarterPrompt(title: "What are the risks?", text: "What are the risks of this?", sendsImmediately: true),
        ChatStarterPrompt(title: "Who else talked about it?", text: "Who else has talked about this, and what did they say?",
                          sendsImmediately: true),
        ChatStarterPrompt(title: "Make the case for it", text: "Make the strongest case for this.", sendsImmediately: true)
    ]

    /// The idea's conversation, created on first use (the title the old view
    /// model gave it, so existing history keeps opening).
    static func conversationID(for idea: Idea, dbPool: DatabasePool) throws -> Int64 {
        try dbPool.write { db in
            if let existing = try ChatConversationQueries.fetchByContext(db, type: contextType, id: String(idea.id)) {
                return existing.id
            }
            return try ChatConversationQueries.create(
                db, title: "Idea: \(String(idea.title.prefix(60)))", contextType: contextType, contextID: String(idea.id)
            ).id
        }
    }

    /// `mentions` are read when the closures run, so a later call with the
    /// loaded list refreshes the center's engine (`EmbeddedChatCenter.engine(for:)`).
    static func spec(idea: Idea, mentions: [IdeaMention], conversationID: Int64, dbPool: DatabasePool) -> ChatSurfaceSpec {
        ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: String(idea.id), conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            systemPrompt: { buildSystemPrompt(idea: idea, mentions: mentions, dbPool: dbPool) },
            // Resumed sessions drop the system prompt (CLI --resume); carry the
            // idea context with the message so an expired session never loses
            // track of what is being discussed.
            turnPrompt: { $0.isResumed ? "\(ideaContextBlock(idea, mentions: mentions))\n\n\($0.text)" : $0.text },
            emptyHint: "Ask me about this idea — I can pull related messages, people, and other ideas.",
            starterPrompts: starterPrompts
        )
    }

    /// Message count of the persisted conversation for an idea — cheap badge
    /// read for the collapsed Discuss header; 0 when no conversation.
    static func persistedMessageCount(_ db: Database, ideaID: Int) throws -> Int {
        guard let conv = try ChatConversationQueries.fetchByContext(
            db, type: contextType, id: String(ideaID)
        ) else { return 0 }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?",
            arguments: [conv.id]
        ) ?? 0
    }

    // MARK: - System prompt

    /// The `=== IDEA ===` block: kind/status/title/essence, plus a
    /// `=== MENTIONS ===` chronology. Also carried with the message on
    /// resumed sessions.
    static func ideaContextBlock(_ idea: Idea, mentions: [IdeaMention]) -> String {
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

    static func buildSystemPrompt(
        idea: Idea,
        mentions: [IdeaMention],
        dbPool: DatabasePool,
        skillsDir: String? = SkillsCatalog.defaultDir()
    ) -> String {
        let brief = (try? dbPool.read { db in try SecretaryProfileQueries.fetch(db) }) ?? ""
        let style = (try? dbPool.read { db in try SecretaryProfileQueries.fetchStyle(db).text }) ?? ""
        let styleBlock = style.isEmpty ? "" : "\n\n=== OWNER'S COMMUNICATION STYLE ===\n\(style)"

        // Assistant skills: whether this surface lists them comes from its
        // context_type via SkillsCatalog.chatContextTypes, and the block is
        // nil when no enabled skill matches, so a workspace with no skills
        // keeps a byte-identical prompt.
        let skillsSuffix = SkillsCatalog.promptBlock(contextType: "idea", dir: skillsDir)
            .map { "\n\n" + $0 } ?? ""

        return """
        You are Watchtower, an AI assistant discussing ONE entry from the user's Ideas & Decisions registry \
        (an idea, decision, or note). Help them think it through — clarify the reasoning, surface risks, \
        or expand on it as asked.

        \(ideaContextBlock(idea, mentions: mentions))

        === WHO THE OWNER IS ===
        \(brief.isEmpty ? "(no brief provided)" : brief)\(styleBlock)

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        You have read-only tools over the user's OWN local Watchtower database. \
        Use them to look things up instead of asking the user:
        - list_ideas / get_idea — the ideas/decisions/notes registry, including every mention across sources.
        - search_knowledge / get_knowledge_document — relevance search across Slack, mail, Jira, Confluence, calendar, \
        transcripts, recaps, digests, decisions and ideas; open a hit in full by its ref. Pass 2-5 queries: \
        key terms, synonyms, Russian and English variants, stems ending in * for Russian word forms.
        - list_messages — search/list the user's Slack messages by person, channel, and/or keyword.
        - get_person / list_people — people cards; get_target / list_tracks / list_digests / list_jira_issues — work context.
        Never ask for a database path, never ask the user to authorize Slack, and never use claude.ai connectors \
        (the Slack connector or any other) — the data is already local and these tools are already connected. \
        If a lookup returns nothing, say so plainly rather than blaming access.
        \(ChatPromptRules.noLiveSourcesRule)

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        """ + skillsSuffix
    }
}
