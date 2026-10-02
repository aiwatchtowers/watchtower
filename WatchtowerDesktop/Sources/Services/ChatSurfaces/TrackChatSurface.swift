import Foundation
import GRDB
import WatchtowerCore

// MARK: - Surface

/// The assistant chat docked under a track (`chat_conversations.context_type
/// = "track"`), on the shared embedded chat component. A draft-only surface
/// (review-rules "The assistant & chat contracts"): no tool mode.
enum TrackChatSurface {
    static let contextType = "track"

    static let starterPrompts = [
        ChatStarterPrompt(title: "What's the latest?", text: "What's the latest on this track?", sendsImmediately: true),
        ChatStarterPrompt(title: "Who's involved?", text: "Who's involved, and who is the ball with?", sendsImmediately: true),
        ChatStarterPrompt(title: "What's blocking it?", text: "What's blocking this, and what would unblock it?",
                          sendsImmediately: true)
    ]

    /// The track's conversation, created on first use.
    static func conversationID(for track: Track, dbPool: DatabasePool) throws -> Int64 {
        try DatabaseEmbeddedChatStore.conversationID(
            dbPool: dbPool, contextType: contextType, contextID: String(track.id),
            title: "Track: \(String(track.text.prefix(60)))")
    }

    /// `track` is the latest row the screen holds: `EmbeddedChatCenter.engine(for:)`
    /// refreshes the spec on every render, so a turn's prompt never reads a
    /// stale snapshot.
    static func spec(track: Track, conversationID: Int64, dbPool: DatabasePool) -> ChatSurfaceSpec {
        ChatSurfaceSpec(
            key: EmbeddedChatKey(contextType: contextType, contextID: String(track.id), conversationID: conversationID),
            persistence: .database(conversationID: conversationID),
            toolAccess: .draftOnly,
            systemPrompt: { buildSystemPrompt(track: track, dbPool: dbPool) },
            emptyHint: "Ask about this track, who's involved, or related discussions.",
            starterPrompts: starterPrompts
        )
    }

    // MARK: - Prompt (text unchanged from the pre-component TrackChatViewModel)

    /// This track's subjects for the MEMORY block: its own channels, every
    /// participant's user id, and the three scalar assignee/owner/requester
    /// user ids — mirroring Go's TrackSubjectRefs (internal/db/memory.go),
    /// reimplemented directly against the same tables since this is a cheap,
    /// simple local read. Also includes the literal alias "track:<id>" so the
    /// track's own memory-mirror entity page (if one exists, Phase 5 slice 4)
    /// can itself surface as a connected entity — mirroring trackMirrorAlias's
    /// prepend on the Go write side (chat_ingest.go).
    static func trackMemorySubjects(track: Track) -> [String] {
        var subjects = Set<String>()
        subjects.insert("track:\(track.id)")
        for channelID in track.decodedChannelIDs where !channelID.isEmpty {
            subjects.insert(channelID)
        }
        for participant in track.decodedParticipants {
            if let userID = participant.userID, !userID.isEmpty { subjects.insert(userID) }
        }
        for userID in [track.assigneeUserID, track.ownerUserID, track.requesterUserID] where !userID.isEmpty {
            subjects.insert(userID)
        }
        return Array(subjects)
    }

    static func buildSystemPrompt(
        track: Track,
        dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir(),
        skillsDir: String? = SkillsCatalog.defaultDir()
    ) -> String {
        let ws: Workspace? = try? dbPool.read { db in
            try WorkspaceQueries.fetchWorkspace(db)
        }
        let teamID = ws?.id ?? "unknown"
        let rawDomain = ws?.domain ?? ""
        let domain = rawDomain.isEmpty ? "unknown" : rawDomain

        let channelIDs = track.decodedChannelIDs
        let channelList = channelIDs.isEmpty ? "none" : channelIDs.joined(separator: ", ")

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — the same pattern
        // MeetingChatSurface's buildSystemPrompt already uses. On the
        // disabled path the block is an empty string, so the prompt is
        // byte-identical to pre-Slice-C output — no memory read runs.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: trackMemorySubjects(track: track), dbPool: dbPool)
              ) + "\n\n"
            : ""

        // Assistant skills: whether this surface lists them comes from its
        // context_type via SkillsCatalog.chatContextTypes, and the block is
        // nil when no enabled skill matches, so a workspace with no skills
        // keeps a byte-identical prompt.
        let skillsSuffix = SkillsCatalog.promptBlock(contextType: contextType, dir: skillsDir)
            .map { "\n\n" + $0 } ?? ""

        return """
        You are Watchtower, an AI assistant helping the user understand a specific track \
        from their Slack workspace.

        === CURRENT TRACK ===
        ID: \(track.id)
        Text: \(track.text)
        Context: \(track.context)
        Category: \(track.category)
        Ownership: \(track.ownership)
        Priority: \(track.priority)
        Requester: \(track.requesterName)
        Blocking: \(track.blocking)
        Channels: \(channelList)
        Created: \(track.createdAt)
        Updated: \(track.updatedAt)

        \(memoryBlock)=== TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        You have read-only tools over the user's OWN local Watchtower database. \
        Use them to look things up instead of asking the user:
        - search_knowledge / get_knowledge_document — relevance search across Slack, mail, Jira, Confluence, calendar, \
        transcripts, recaps, digests, decisions and ideas; open a hit in full by its ref. Pass 2-5 queries: \
        key terms, synonyms, Russian and English variants, stems ending in * for Russian word forms.
        - list_messages — search/list the user's Slack messages by person, channel, and/or keyword, \
        newest first. Pass this track's channel ids (listed above) as `channel` to scan its traffic.
        - get_person / list_people — people cards; list_targets / get_target, list_tracks, \
        list_digests, list_jira_issues — work context.
        \(ChatPromptRules.noLiveSourcesRule)

        === WORKSPACE ===
        Slack team ID: \(teamID)
        Slack web domain: \(domain).slack.com

        \(Self.linkingGuidance(teamID: teamID, domain: domain))
        """ + skillsSuffix + "\n\n" + ChatQuestionsContract.promptBlock
    }

    /// LINKING RULES / RESPONSE STYLE guidance shared by buildSystemPrompt's
    /// returned prompt. Extracted purely to keep buildSystemPrompt under the
    /// function-body-length limit.
    private static func linkingGuidance(
        teamID: String,
        domain: String
    ) -> String {
        """
        === LINKING RULES ===
        ALWAYS use markdown links with descriptive text in the user's language. Never output bare URLs.

        Channel link:
          [#channel-name](slack://channel?team=\(teamID)&id={channel_id})

        Message link (top-level message, thread_ts is NULL or empty):
          [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={ts})

        Message link inside a thread — use thread_ts (the parent's ts), NOT the reply's ts:
          [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={thread_ts})

        Web permalink (only when the user explicitly asks for an https link):
          Top-level:     https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}
          Thread reply:  https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}?thread_ts={thread_ts}&cid={channel_id}
          Remove the dot from ts: 1740577800.000100 → p1740577800000100

        Rules:
        - Every referenced message MUST have a link
        - Link text describes WHAT is linked, not "link" or "click here"
        - list_messages returns channel_id, ts, and thread_ts for every message, so you can always build correct links
        - \(ChatPromptRules.knowledgeLinkRule)
        - NEVER link to a channel when the user asked for a specific message — resolve the actual ts first

        === RESPONSE STYLE ===
        - Be concise and direct
        - Match the user's language
        - Use markdown for readability
        """
    }
}
