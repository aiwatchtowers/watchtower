import Foundation
import GRDB
import WatchtowerCore

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var text: String
    var timestamp: Date
    var isStreaming: Bool
    var turnID: String?

    enum Role: Equatable {
        case user
        case assistant
        case system
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }
}

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?
    var selectedProvider: AIProvider = .claude
    /// Model override for this chat; empty = the provider's resolved
    /// strong-tier model (the CLI resolves it — see `watchtower ai models`).
    var selectedModel: String = ""

    private(set) var conversationID: Int64?
    private var sessionID: String?
    private var aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private var streamTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    /// Guards against persisting the streaming assistant reply twice: `cancelStream()`
    /// persists the partial text synchronously, but the stream Task's own completion
    /// tail still runs afterward (it keeps draining/finishing the underlying stream
    /// even once cancelled) and would otherwise persist the same reply again. Reset
    /// at the start of every new stream.
    private var responsePersistedOnCancel = false

    /// Callback to notify history that title/session changed
    var onConversationUpdated: ((Int64, String?, String?) -> Void)?

    /// Proposal cards for the bound conversation — the main chat is an
    /// action surface (AGENT-04): write tools land here behind Approve.
    let actionFeed: AgentActionFeed

    /// Only CLI-backed providers reach the MCP server; Ollama has no tools,
    /// so the prompt says so and no tool mode is sent.
    var toolsAvailable: Bool { selectedProvider != .ollama }

    init(
        aiService: any AIServiceProtocol,
        dbManager: DatabaseManager,
        provider: AIProvider = .claude,
        cliRunner: CLIRunnerProtocol? = nil
    ) {
        self.aiService = aiService
        self.dbManager = dbManager
        self.selectedProvider = provider
        self.actionFeed = AgentActionFeed(dbPool: dbManager.dbPool, cliRunner: cliRunner)
    }

    func switchProvider(_ provider: AIProvider) {
        guard provider != selectedProvider else { return }
        cancelStream()
        selectedProvider = provider
        selectedModel = ""
        aiService = Self.createService(for: provider)
    }

    // `WatchtowerAIService` talks to a single CLI binary that serves both
    // providers via `watchtower ai query --provider <claude|codex>` (see
    // `send()`/`sendWelcomeMessage()` below), so the same service instance
    // works regardless of which provider is selected — no per-provider
    // service type is needed here.
    static func createService(for provider: AIProvider) -> any AIServiceProtocol {
        _ = provider
        return WatchtowerAIService()
    }

    func bind(to conversation: ChatConversation) {
        // If switching to a different conversation, load from DB
        if conversationID != conversation.id {
            cancelStream()
            observationTask?.cancel()
            observationTask = nil
            messages.removeAll()
            errorMessage = nil
            conversationID = conversation.id
            sessionID = conversation.sessionID
            loadMessages(conversationID: conversation.id)
            startMessageObservation()
            actionFeed.start(conversationID: conversation.id)
        }
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        streamTask?.cancel()
        inputText = ""
        let previousOwnerMessageAt = messages.last { $0.role == .user }?.timestamp
        let turnID = UUID().uuidString
        messages.append(ChatMessage(id: UUID(), role: .user, text: text, timestamp: Date(), isStreaming: false))

        if let convID = conversationID {
            persistMessage(conversationID: convID, role: "user", text: text)
        }

        messages.append(ChatMessage(id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true, turnID: turnID))
        isStreaming = true
        responsePersistedOnCancel = false

        autoGenerateTitle(text: text)

        let currentSessionID = sessionID
        let dbPath = dbManager.dbPool.path
        let dbPool = dbManager.dbPool
        let model: String? = selectedModel.isEmpty ? nil : selectedModel
        let provider = selectedProvider.rawValue
        let capturedConvID = conversationID
        let capturedDBManager = dbManager
        let capturedAIService = aiService
        let capturedToolsAvailable = toolsAvailable
        let toolMode = Self.makeToolMode(toolsAvailable: capturedToolsAvailable, conversationID: capturedConvID, turnID: turnID)
        // Outcomes are injected only on resumed turns — a fresh turn has no
        // prior assistant turn whose proposals could have been decided yet.
        let outcomes = currentSessionID == nil ? nil : actionFeed.outcomesBlock(after: previousOwnerMessageAt)
        let effectivePrompt = outcomes.map { "\($0)\n\n\(text)" } ?? text

        streamTask = Task { [weak self] in
            let systemPrompt: String? = currentSessionID == nil
                ? Self.buildSystemPrompt(dbPool: dbPool, toolsAvailable: capturedToolsAvailable)
                : nil

            var fullText = ""
            var newSessionID: String?
            do {
                let stream = capturedAIService.stream(
                    prompt: effectivePrompt,
                    systemPrompt: systemPrompt,
                    sessionID: currentSessionID,
                    dbPath: dbPath,
                    model: model,
                    provider: provider,
                    toolMode: toolMode
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
                        self?.updateLastMessage(fullText)
                    case .turnComplete(let text):
                        fullText = text
                        sawTurnComplete = true
                        self?.updateLastMessage(fullText)
                    case .sessionID(let sid):
                        newSessionID = sid
                        self?.sessionID = sid
                        if let convID = capturedConvID {
                            self?.onConversationUpdated?(convID, nil, sid)
                        }
                    case .done:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }

            // Always persist the response, even if self is gone — unless
            // cancelStream() already persisted this same partial reply (see
            // `responsePersistedOnCancel`); skipping avoids a duplicate row.
            if !fullText.isEmpty, let convID = capturedConvID, self?.responsePersistedOnCancel != true {
                Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText, turnID: turnID)
            }
            if let sid = newSessionID, let convID = capturedConvID {
                Self.persistSessionStatic(dbManager: capturedDBManager, conversationID: convID, sessionID: sid)
            }

            self?.finishStream()
        }
    }

    private func autoGenerateTitle(text: String) {
        let isFirstMessage = messages.filter { $0.role == .user }.count == 1
        if isFirstMessage, let convID = conversationID {
            onConversationUpdated?(convID, String(text.prefix(80)), nil)
        }
    }

    /// The main chat is an action surface only once it has a conversation to
    /// attach proposals to (AGENT-04) and a provider that reaches the MCP
    /// server (`toolsAvailable`); otherwise no tool mode is sent.
    nonisolated private static func makeToolMode(toolsAvailable: Bool, conversationID: Int64?, turnID: String) -> ChatToolMode? {
        guard toolsAvailable, let conversationID else { return nil }
        return ChatToolMode(surface: "main", conversationID: conversationID, turnID: turnID)
    }

    private func updateLastMessage(_ text: String) {
        if let idx = messages.indices.last {
            messages[idx].text = text
        }
    }

    private func finishStream() {
        if let idx = messages.indices.last {
            messages[idx].isStreaming = false
        }
        isStreaming = false
        if let convID = conversationID {
            onConversationUpdated?(convID, nil, nil)
        }
    }

    // MARK: - Static persistence (works even if self is deallocated)

    nonisolated private static func persistResponseStatic(dbManager: DatabaseManager, conversationID: Int64, text: String, turnID: String) {
        _ = try? dbManager.dbPool.write { db in
            try ChatMessageQueries.insert(db, conversationID: conversationID, role: "assistant", text: text, turnID: turnID)
            try ChatConversationQueries.touch(db, id: conversationID)
        }
    }

    nonisolated private static func persistSessionStatic(dbManager: DatabaseManager, conversationID: Int64, sessionID: String) {
        _ = try? dbManager.dbPool.write { db in
            try ChatConversationQueries.updateSessionID(db, id: conversationID, sessionID: sessionID)
        }
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let idx = messages.indices.last, messages[idx].isStreaming {
            // Save partial assistant response if non-empty
            let partialText = messages[idx].text
            if !partialText.isEmpty, let convID = conversationID {
                persistMessage(conversationID: convID, role: "assistant", text: partialText, turnID: messages[idx].turnID ?? "")
                // Tell the still-running stream Task's completion tail not to
                // persist this reply again — cancellation is cooperative, so
                // that tail keeps executing after this synchronous save.
                responsePersistedOnCancel = true
            }
            messages[idx].isStreaming = false
        }
    }

    func newChat() {
        // H9: cancel in-flight stream before clearing
        cancelStream()
        observationTask?.cancel()
        observationTask = nil
        messages.removeAll()
        sessionID = nil
        conversationID = nil
        errorMessage = nil
        actionFeed.stop()
    }

    // MARK: - Observation

    /// Observe chat_messages for this conversation so background-persisted
    /// responses (from a stream that outlived a previous ViewModel) appear automatically.
    private func startMessageObservation() {
        guard let convID = conversationID else { return }
        let dbPool = dbManager.dbPool
        observationTask = Task { [weak self] in
            let observation = ValueObservation.tracking { db in
                try ChatMessageQueries.fetchByConversation(db, conversationID: convID)
            }
            do {
                for try await records in observation.values(in: dbPool).dropFirst() {
                    guard !Task.isCancelled else { break }
                    guard let self, !self.isStreaming else { continue }
                    if records.count != self.messages.count {
                        self.messages = records.map { $0.toChatMessage() }
                    }
                }
            } catch {}
        }
    }

    // MARK: - Persistence

    private func loadMessages(conversationID: Int64) {
        do {
            let records = try dbManager.dbPool.read { db in
                try ChatMessageQueries.fetchByConversation(db, conversationID: conversationID)
            }
            messages = records.map { $0.toChatMessage() }
        } catch {
            // silently ignore
        }
    }

    private func persistMessage(conversationID: Int64, role: String, text: String, turnID: String = "") {
        _ = try? dbManager.dbPool.write { db in
            try ChatMessageQueries.insert(db, conversationID: conversationID, role: role, text: text, turnID: turnID)
        }
    }

    // MARK: - System Prompt

    // H2: static method avoids capturing self in GRDB closure
    nonisolated static func buildSystemPrompt(dbPool: DatabasePool, toolsAvailable: Bool = true) -> String {
        do {
            return try dbPool.read { db in
                let ws = try WorkspaceQueries.fetchWorkspace(db)
                let schema = try Self.fetchSchema(db)
                return Self.formatSystemPrompt(workspace: ws, schema: schema, toolsAvailable: toolsAvailable)
            }
        } catch {
            return "You are Watchtower, an AI assistant for Slack workspace analysis. Use the local Watchtower tools to answer questions."
        }
    }

    nonisolated static func formatSystemPrompt(
        workspace ws: Workspace?,
        schema: String,
        toolsAvailable: Bool = true
    ) -> String {
        let name = ws?.name ?? "unknown"
        let domain = ws?.domain ?? "unknown"
        let teamID = ws?.id ?? "unknown"

        let now = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return fmt.string(from: Date())
        }()

        let toolsBlock = toolsAvailable
            ? AgentToolsContract.promptBlock(surface: .main) + "\n\n"
            : ""

        return promptHeader(name: name, domain: domain, now: now, schema: schema, toolsAvailable: toolsAvailable)
            + toolsBlock
            + promptDeepLinksAndRestrictions(teamID: teamID)
            + promptRules(teamID: teamID)
            + promptAppGuide()
    }

    nonisolated private static func promptHeader(
        name: String,
        domain: String,
        now: String,
        schema: String,
        toolsAvailable: Bool
    ) -> String {
        let toolsSection = toolsAvailable
            ? """
            IMPORTANT: You MUST look things up with the tools below to answer every question.
            You have NO pre-loaded data — the local database is your only source of truth.

            === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
            - list_messages — search/list raw Slack messages by person, channel, and/or keyword, newest first. \
            At least one of person/channel/query is required.
            - list_people / get_person — people cards; list_tracks / get_track — work narratives.
            - list_targets / get_target — the user's action items and goals.
            - get_today_briefing / list_digests / get_digest — the daily briefing and AI summaries of Slack activity.
            - list_jira_issues / get_jira_issue — synced Jira issues.
            - list_transcripts / get_transcript — recorded meeting transcripts.
            - list_upcoming_events — calendar events in the next N hours.
            - memory_recall / memory_open / memory_map — the assistant's long-term memory, once it has been built.
            Never ask for a database path; the data is already local and the tools are already connected.
            """
            : AgentToolsContract.noToolsBlock

        return """
        You are Watchtower, an AI assistant that answers questions about a Slack workspace from its local database.

        Workspace: "\(name)" (domain: \(domain).slack.com)
        Current time: \(now)

        \(toolsSection)

        There is no SQL tool and no shell — you cannot run database or shell commands of any kind. \
        The schema below documents the fields behind those tools; read it as reference, never as something to execute.

        === DATABASE SCHEMA (reference) ===
        \(schema)

        """
    }

    /// The data-access ground rule shared by every chat surface's system
    /// prompt. Written against a real failure mode: tools the model cannot use
    /// get silently denied in headless mode, so an unbriefed model wastes a
    /// turn trying them and then asks the user to "approve tool permissions".
    nonisolated static let noLiveSourcesRule = """
        You have NO shell, NO filesystem access, NO internet, and NO live access to Slack, Jira, \
        or Calendar — the local Watchtower database already mirrors them, and the tools listed above \
        are the ONLY way in. Never say you will check an external system, and never ask the user to \
        approve tool permissions: everything you can use is already connected; everything else is \
        unavailable by design.
        """

    nonisolated private static func promptDeepLinksAndRestrictions(teamID: String) -> String {
        """
        Deep link format:
          slack://channel?team=\(teamID)&id={channel_id}&message={ts}
          Example: ts "1740577800.000100" →
          slack://channel?team=\(teamID)&id=C123&message=1740577800.000100

        === IMPORTANT RESTRICTIONS ===
        - You have NO internet access. Do NOT call any Slack API, WebFetch, or WebSearch tools.
        - Your ONLY data source is the local database, reached through the tools above. \
        You cannot write directly — every write is a proposal through a write tool, executed only after the owner approves.

        """
    }

    nonisolated private static func promptRules(teamID: String) -> String {
        """
        === WORKFLOW ===
        1. Look the data up with the tools above (start with list_messages for raw Slack traffic)
        2. If results are empty or insufficient, broaden the lookup (wider filters, different keywords)
        3. Analyze the actual message content from the results
        4. Respond with insights, organized by channel or topic
        5. Include Slack permalinks for key messages

        === LINKING RULES ===
        ALWAYS include Slack links as descriptive markdown — never bare URLs.

        Channel link: [#channel-name](slack://channel?team=\(teamID)&id={channel_id})
        Message link: [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={ts})
          Use the raw ts value (with dot). Example: "1740577800.000100" → message=1740577800.000100

        Rules:
        - Every channel mention (#name) MUST be a link to that channel
        - Every referenced message or thread MUST have a link with descriptive text in the user's language
        - The tools return channel_id and ts for every message, so you can always build links

        === RESPONSE STYLE ===
        - Be concise and direct — give the answer, not the process
        - Do NOT describe your search steps, reasoning, or tool usage. Present findings directly.
        - Match the user's language and tone
        - Use markdown for readability (headers, bullet lists, bold for emphasis)
        - Use line breaks between sections for clarity
        - Highlight: decisions, tracks, unanswered questions, unusual activity
        """
    }

    nonisolated private static func promptAppGuide() -> String {
        """

        === WATCHTOWER APP GUIDE ===
        You are also an expert on the Watchtower app itself. When users ask about features,
        how to use the app, or what something means — answer based on this guide.

        Watchtower is a macOS desktop app that syncs a Slack workspace to a local SQLite database
        and uses AI to generate insights: daily briefings, inbox, calendar with meeting prep, digests, tracks, and people analytics.

        TABS:
        - AI Chat: chat with AI about workspace data. Provider selector (Claude/Codex), model selector.
          Claude: Sonnet/Haiku/Opus; Codex: GPT-5.4/GPT-5.4 Mini/GPT-5.3 Codex.
          Multi-turn with session memory (Claude only; Codex is ephemeral).
          Calendar events (48h) injected into context
        - Briefings: personalized daily overview — today's schedule (calendar events), needs attention, your day, what happened, team pulse, coaching
        - Inbox: messages awaiting your response — @mentions and DMs auto-detected after each sync, AI-prioritized (high/medium/low), auto-resolved when you reply. Statuses: pending, resolved, dismissed, snoozed. Actions: resolve, dismiss, snooze, create task, open in Slack
        - Calendar: Google Calendar integration — today's and tomorrow's events, meeting prep (AI-generated talking points, open items, people notes, suggested prep). Connect in Settings. Events highlight: green=happening now, blue=upcoming within 1 hour
        - Tasks: personal action items with priority, ownership, due dates, sub-items. Sources: track, briefing, digest, inbox, manual, chat
        - Tracks: auto-generated narrative summaries of ongoing initiatives from digests (priority: high/medium/low; narrative, timeline, participants, key messages)
        - Digests: AI summaries of channel activity (channel/daily/weekly), with topics, decisions, running context
        - Decisions: flat list of all decisions across digests, with importance ratings
        - People: team member profiles from AI analysis — communication style, decision role, accomplishments, red flags, activity hours
        - Statistics: channel analytics, bot traffic %, recommendations (mute/leave/favorite), mute channels for AI
        - Search: full-text search across all synced Slack messages
        - Usage: token consumption and costs by date, model, feature; live pipeline progress
        - Training: prompt editor, feedback stats, quality score, tuning controls

        SETTINGS: sync interval, workers, history depth, AI provider (Claude/Codex), digest model/language, briefing hour,
        Claude CLI path, Codex CLI path (when Codex selected), Google Calendar (connect/disconnect, sync days ahead),
        Jira (OAuth, board selection, Board Profiles with workflow viz and stale sliders,
        User Mapping, sync status, Feature toggles by category and role),
        profile (role, team, manager, reports, peers), notifications, daemon control, logs, data management.

        BACKGROUND PROCESSES: daemon syncs Slack periodically, then runs pipelines:
        calendar sync → inbox (detect + AI prioritize) → channel digests → tracks → rollup digests → people → briefing (automatic after each sync).
        Also auto-unsnoozes tasks and inbox items past their snooze date.

        KEY CONCEPTS:
        - Running context: AI maintains per-channel memory (active topics, decisions, open questions)
        - Situations: extracted interaction patterns used to build people cards
        - Feedback loop: thumbs up/down + importance corrections improve AI via prompt tuning
        - Starred items: prioritize specific channels and people in analysis
        - Muted channels: excluded from AI processing to reduce noise and token costs
        - Google Calendar: optional integration syncing events to local DB, enabling meeting prep and schedule-aware briefings/chat
        - Jira Cloud: optional integration via OAuth. Board Profiles (LLM-analyzed workflow stages,
          stale thresholds, health signals). Issues sync every 15 min. Jira keys (PROJ-123)
          auto-detected in Slack. Feature toggles by role (Your Work, Team, Product, Automation).
          CLI: jira login/logout/status, boards/select/analyze, users/map, sync, features

        When answering about the app, be specific and accurate. Do not invent features that don't exist.
        """
    }

    // MARK: - Welcome Message

    /// Send a welcome message in a new chat, using the user's profile for personalization.
    func sendWelcomeMessage(profile: UserProfile, language: String = "English") {
        guard !isStreaming else { return }

        let welcomePrompt = Self.buildWelcomePrompt(profile: profile, language: language)

        messages.append(ChatMessage(id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true))
        isStreaming = true
        responsePersistedOnCancel = false

        let dbPath = dbManager.dbPool.path
        let dbPool = dbManager.dbPool
        let model: String? = selectedModel.isEmpty ? nil : selectedModel
        let provider = selectedProvider.rawValue
        let capturedConvID = conversationID
        let capturedDBManager = dbManager
        let capturedAIService = aiService

        streamTask = Task { [weak self] in
            let systemPrompt = Self.buildSystemPrompt(dbPool: dbPool)

            var fullText = ""
            var newSessionID: String?
            do {
                let stream = capturedAIService.stream(
                    prompt: welcomePrompt,
                    systemPrompt: systemPrompt,
                    sessionID: nil,
                    dbPath: dbPath,
                    model: model,
                    provider: provider
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
                        self?.updateLastMessage(fullText)
                    case .turnComplete(let text):
                        fullText = text
                        sawTurnComplete = true
                        self?.updateLastMessage(fullText)
                    case .sessionID(let sid):
                        newSessionID = sid
                        self?.sessionID = sid
                        if let convID = capturedConvID {
                            self?.onConversationUpdated?(convID, nil, sid)
                        }
                    case .done:
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self?.errorMessage = error.localizedDescription
                }
            }

            if !fullText.isEmpty, let convID = capturedConvID, self?.responsePersistedOnCancel != true {
                Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText, turnID: "")
            }
            if let sid = newSessionID, let convID = capturedConvID {
                Self.persistSessionStatic(dbManager: capturedDBManager, conversationID: convID, sessionID: sid)
            }

            self?.finishStream()
        }
    }

    nonisolated private static func buildWelcomePrompt(profile: UserProfile, language: String) -> String {
        var parts: [String] = []
        parts.append("IMPORTANT: You MUST respond entirely in \(language).")
        parts.append("""
            This is the user's FIRST time opening Watchtower after onboarding. \
            Write a welcome message that serves as a quick tour of the app. \
            Structure it as a friendly, concise guide to what Watchtower does and how to use it.

            Cover these features in order, briefly (1-2 sentences each):
            1. **Briefings** — personalized daily morning overview combining all insights (needs attention, your day, what happened, team pulse, coaching)
            2. **Inbox** — messages awaiting your response (@mentions and DMs), auto-detected and AI-prioritized
            3. **Tasks** — personal action items you create from tracks, briefings, digests, or inbox items
            4. **Chat** (this tab!) — ask questions about your workspace, activity, decisions, people
            5. **Tracks** — auto-generated narratives about ongoing initiatives across channels
            6. **Digests** — AI summaries of channel activity, decisions, and trends
            7. **People** — team member profiles with communication style, activity patterns
            8. **Statistics** — channel analytics, digest coverage, recommendations to mute noisy channels

            Then mention:
            - The background daemon syncs Slack data automatically and runs AI pipelines after each sync
            - They can rate AI quality with thumbs up/down to improve results over time
            - Settings (⌘,) let them configure sync frequency, language, notifications, etc.

            End with a friendly invitation to ask anything or explore the tabs on the left.
            """)

        if !profile.role.isEmpty {
            parts.append("User's role: \(profile.role). Tailor examples to this role.")
        }
        if !profile.painPoints.isEmpty, profile.painPoints != "[]" {
            parts.append("User's pain points: \(profile.painPoints). Mention which features address these.")
        }

        parts.append("""
            Format: use **bold** for feature names, keep total length under 400 words. \
            Be warm but not cheesy. No emojis unless the language culturally expects them.
            """)

        return parts.joined(separator: "\n")
    }

    /// Fetch the database schema (CREATE TABLE statements)
    nonisolated static func fetchSchema(_ db: Database) throws -> String {
        let rows = try Row.fetchAll(db, sql: """
            SELECT sql FROM sqlite_master
            WHERE type IN ('table', 'view') AND sql IS NOT NULL
            ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, name
        """)
        return rows.compactMap { $0["sql"] as? String }.joined(separator: ";\n\n")
    }
}
