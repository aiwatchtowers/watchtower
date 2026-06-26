import Foundation
import GRDB

// MARK: - Action card

struct TargetActionCard: Identifiable, Equatable {
    let id = UUID()
    let messageID: UUID
    let action: ProposedAction
    var state: State

    enum State: Equatable {
        case pending
        case applied(String)
        case rejected
        case failed(String)
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class TargetChatViewModel {
    var messages: [ChatMessage] = []
    var actionCards: [TargetActionCard] = []
    var isStreaming = false
    var inputText = ""
    var errorMessage: String?
    var selectedModel: ChatModel

    /// Configured AI provider — scopes the model picker so we never hand a
    /// codex model to a claude session (the model is the only real lever; the
    /// provider itself is config-driven in WatchtowerAIService).
    let provider: AIProvider

    private var conversationID: Int64?
    private var sessionID: String?
    private let aiService: any AIServiceProtocol
    private let dbManager: DatabaseManager
    private var target: Target
    private let viewModel: TargetsViewModel
    private var streamTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    init(
        target: Target,
        viewModel: TargetsViewModel,
        dbManager: DatabaseManager,
        aiService: (any AIServiceProtocol)? = nil,
        provider: AIProvider? = nil
    ) {
        self.target = target
        self.viewModel = viewModel
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()
        let resolvedProvider = provider
            ?? (ConfigService().aiProvider == "codex" ? .codex : .claude)
        self.provider = resolvedProvider
        self.selectedModel = ChatModel.defaultModel(for: resolvedProvider)

        loadOrCreateConversation()
        startMessageObservation()
    }

    private func loadOrCreateConversation() {
        do {
            if let existing = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByContext(
                    db, type: "target", id: String(target.id)
                )
            }) {
                let records = try dbManager.dbPool.read { db in
                    try ChatMessageQueries.fetchByConversation(
                        db, conversationID: existing.id
                    )
                }
                conversationID = existing.id
                sessionID = existing.sessionID
                messages = records.map { $0.toChatMessage() }
                return
            }
            let conv = try dbManager.dbPool.write { db in
                try ChatConversationQueries.create(
                    db,
                    title: "Task: \(String(target.text.prefix(60)))",
                    contextType: "target",
                    contextID: String(target.id)
                )
            }
            conversationID = conv.id
            sessionID = conv.sessionID
            messages = []
        } catch {
            errorMessage = "Failed to load conversation: \(error.localizedDescription)"
        }
    }

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
            } catch {
                print("TargetChat: message observation stopped: \(error)")
            }
        }
    }

    func send() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        streamTask?.cancel()
        inputText = ""

        messages.append(ChatMessage(
            id: UUID(),
            role: .user,
            text: text,
            timestamp: Date(),
            isStreaming: false
        ))

        if let convID = conversationID {
            persistMessage(conversationID: convID, role: "user", text: text)
        }

        messages.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "",
            timestamp: Date(),
            isStreaming: true
        ))
        startStream(prompt: text)
    }

    private func sendFollowUp(_ text: String) {
        guard !isStreaming else { return }
        streamTask?.cancel()
        appendSystemMessage(text)
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))
        startStream(prompt: text)
    }

    /// Spawn the streaming turn. Shared by `send()` and `sendFollowUp(_:)` —
    /// the caller is responsible for appending the user/system message and the
    /// empty assistant placeholder before calling this.
    private func startStream(prompt: String) {
        isStreaming = true
        let currentSessionID = sessionID
        let dbPath = dbManager.dbPool.path
        let dbPool = dbManager.dbPool
        let capturedTarget = target
        let capturedAIService = aiService
        let capturedConvID = conversationID
        let capturedDBManager = dbManager

        streamTask = Task { [weak self] in
            await self?.executeStream(
                text: prompt,
                currentSessionID: currentSessionID,
                target: capturedTarget,
                dbPool: dbPool,
                dbPath: dbPath,
                aiService: capturedAIService,
                dbManager: capturedDBManager,
                conversationID: capturedConvID
            )
        }
    }

    // MARK: - Stream execution

    private func executeStream(
        text: String,
        currentSessionID: String?,
        target: Target,
        dbPool: DatabasePool,
        dbPath: String,
        aiService: any AIServiceProtocol,
        dbManager: DatabaseManager,
        conversationID: Int64?
    ) async {
        let systemPrompt: String? = currentSessionID == nil
            ? Self.buildSystemPrompt(target: target, dbPool: dbPool)
            : nil

        var fullText = ""
        var streamFailed = false
        do {
            let stream = aiService.stream(
                prompt: text,
                systemPrompt: systemPrompt,
                sessionID: currentSessionID,
                dbPath: dbPath,
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
        } catch {
            streamFailed = true
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
            }
        }

        // On a failed/cancelled stream, do NOT parse actions out of partial,
        // possibly-truncated output — that could surface a half-formed proposal.
        if streamFailed {
            finishStream()
            return
        }

        // Parse watchtower-action blocks out of the final text.
        let parsed = TargetActionParser.parse(fullText)
        // When the AI emits only an action block, visible prose is empty; show a
        // placeholder so the turn isn't blank and gets persisted into the transcript.
        let displayText = parsed.text.isEmpty && !parsed.actions.isEmpty
            ? "(proposed \(parsed.actions.count) action(s))"
            : parsed.text
        updateLastMessage(displayText)

        let assistantMessageID = messages.indices.last.map { messages[$0].id } ?? UUID()
        for action in parsed.actions {
            actionCards.append(TargetActionCard(
                messageID: assistantMessageID, action: action, state: .pending
            ))
        }
        for err in parsed.errors {
            appendSystemMessage("⚠️ Invalid action proposal: \(err)")
        }

        if !displayText.isEmpty, let convID = conversationID {
            Self.persistResponse(dbManager: dbManager, conversationID: convID, text: displayText)
        }

        finishStream()
    }

    // MARK: - Persistence helpers

    nonisolated private static func persistResponse(
        dbManager: DatabaseManager, conversationID: Int64, text: String
    ) {
        _ = try? dbManager.dbPool.write { db in
            try ChatMessageQueries.insert(
                db, conversationID: conversationID, role: "assistant", text: text
            )
            try ChatConversationQueries.touch(db, id: conversationID)
        }
    }

    private func updateLastMessage(_ text: String) {
        if let idx = messages.indices.last {
            messages[idx].text = text
        }
    }

    private func appendSystemMessage(_ text: String) {
        messages.append(ChatMessage(
            id: UUID(), role: .system, text: text, timestamp: Date(), isStreaming: false
        ))
        if let convID = conversationID {
            persistMessage(conversationID: convID, role: "system", text: text)
        }
    }

    /// Approve a proposed action. `kind` lets the user override what gets created
    /// for the interchangeable add_sub_item / create_child_target proposals
    /// (checkpoint vs sub-task); nil keeps the AI's proposed kind.
    func approve(_ card: TargetActionCard, as kind: TargetActionKind? = nil) {
        guard let idx = actionCards.firstIndex(where: { $0.id == card.id }),
              actionCards[idx].state == .pending else { return }
        let action = Self.resolved(card.action, overrideKind: kind)
        reloadTarget()
        do {
            let summary = try TargetActionExecutor.apply(action, target: target, viewModel: viewModel)
            actionCards[idx].state = .applied(summary)
            reloadTarget()
            sendFollowUp("Action applied: \(summary). Continue with the task.")
        } catch {
            actionCards[idx].state = .failed(error.localizedDescription)
            sendFollowUp("Action FAILED: \(error.localizedDescription). " +
                         "Do NOT assume it was applied; suggest how to proceed.")
        }
    }

    func reject(_ card: TargetActionCard) {
        guard let idx = actionCards.firstIndex(where: { $0.id == card.id }),
              actionCards[idx].state == .pending else { return }
        actionCards[idx].state = .rejected
        sendFollowUp("User rejected the action (reason given: \(card.action.reason)). " +
                     "Suggest an alternative or ask what to do.")
    }

    /// Return `action` with its `type` swapped to `kind` (keeping text/intent/etc.).
    /// Used to let the user pick checkpoint vs sub-task at approve time.
    private static func resolved(_ action: ProposedAction, overrideKind kind: TargetActionKind?) -> ProposedAction {
        guard let kind, kind != action.type else { return action }
        return ProposedAction(
            type: kind, reason: action.reason, status: action.status, note: action.note,
            progress: action.progress, text: action.text, intent: action.intent,
            priority: action.priority, targetId: action.targetId, relation: action.relation
        )
    }

    private func handleSessionID(_ sid: String) {
        self.sessionID = sid
        if let convID = conversationID {
            persistSessionID(conversationID: convID, sessionID: sid)
        }
    }

    private func finishStream() {
        // Clear every streaming flag, not just the last message: appending
        // system messages (e.g. invalid-action warnings) after the assistant
        // placeholder would otherwise leave the placeholder stuck "streaming".
        for idx in messages.indices where messages[idx].isStreaming {
            messages[idx].isStreaming = false
        }
        isStreaming = false
        reloadTarget()
        viewModel.load()
    }

    func cancelStream() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        if let idx = messages.indices.last, messages[idx].isStreaming {
            let partialText = messages[idx].text
            if !partialText.isEmpty, let convID = conversationID {
                persistMessage(conversationID: convID, role: "assistant", text: partialText)
            }
            messages[idx].isStreaming = false
        }
    }

    private func persistMessage(conversationID: Int64, role: String, text: String) {
        _ = try? dbManager.dbPool.write { db in
            try ChatMessageQueries.insert(
                db, conversationID: conversationID, role: role, text: text
            )
        }
    }

    private func reloadTarget() {
        do {
            if let updated = try dbManager.dbPool.read({ db in
                try TargetQueries.fetchByID(db, id: target.id)
            }) {
                target = updated
            }
        } catch {
            print("TargetChat: reloadTarget failed: \(error)")
        }
    }

    private func persistSessionID(conversationID: Int64, sessionID: String) {
        _ = try? dbManager.dbPool.write { db in
            try ChatConversationQueries.updateSessionID(
                db, id: conversationID, sessionID: sessionID
            )
        }
    }

    /// The action contract injected into the system prompt. Lists the five
    /// supported watchtower-action types and their required fields; the AI
    /// emits these instead of writing to the DB. Kept as a constant so
    /// buildSystemPrompt stays focused on task/workspace context.
    nonisolated static let taskActionsContract = """
    === TASK ACTIONS ===
    To change THIS task, do NOT write to the database and do NOT call any write tool.
    Instead output a fenced block exactly like:
    ```watchtower-action
    { "type": "<action>", ...fields, "reason": "<why>" }
    ```
    One JSON object per block; emit multiple blocks for multiple actions.
    After emitting a block, STOP and wait — do NOT assume it was applied.
    Supported actions and required fields:
    - update_status      { "status": "todo|in_progress|blocked|done|dismissed|snoozed" }
    - update_notes       { "note": "<text to append>" }
    - update_progress    { "progress": <0-100 integer> }
    - add_sub_item       { "text": "<sub-item text>" }
    - create_child_target{ "text": "<title>", "intent": "<goal>", "priority": "high|medium|low" }
    - link_target        { "target_id": <id of an EXISTING target>, "relation": "contributes_to|blocks|related|duplicates" }
    Every block must also include "reason".
    For link_target, first look up the other target's id by querying the `targets`
    table (e.g. SELECT id, text FROM targets WHERE ...); never guess an id.
    """

    /// The `=== CURRENT TASK ===` context block for the system prompt, with
    /// notes and sub-items rendered as plain text (not raw JSON).
    nonisolated private static func taskContextBlock(_ target: Target) -> String {
        let notesList = target.decodedNotes.map { "- \($0.text)" }.joined(separator: "\n")
        let notesText = notesList.isEmpty ? "(none)" : notesList
        let subItemsList = target.decodedSubItems
            .map { "- [\($0.done ? "x" : " ")] \($0.text)" }
            .joined(separator: "\n")
        let subItemsText = subItemsList.isEmpty ? "(none)" : subItemsList
        return """
        === CURRENT TASK ===
        ID: \(target.id)
        Text: \(target.text)
        Intent: \(target.intent)
        Status: \(target.status)
        Priority: \(target.priority)
        Ownership: \(target.ownership)
        Blocking: \(target.blocking)
        Progress: \(Int((target.progress * 100).rounded()))%
        Notes:
        \(notesText)
        Sub-items:
        \(subItemsText)
        Created: \(target.createdAt)
        Updated: \(target.updatedAt)
        """
    }

    nonisolated static func buildSystemPrompt(
        target: Target, dbPool: DatabasePool
    ) -> String {
        let schema = (try? dbPool.read { db in
            try ChatViewModel.fetchSchema(db)
        }) ?? ""
        let dbPath = dbPool.path

        let ws: Workspace? = try? dbPool.read { db in
            try WorkspaceQueries.fetchWorkspace(db)
        }
        let teamID = ws?.id ?? "unknown"
        let rawDomain = ws?.domain ?? ""
        let domain = rawDomain.isEmpty ? "unknown" : rawDomain

        return """
        You are Watchtower, an AI assistant helping the user make progress on a specific \
        task (target) tracked in their workspace.

        \(Self.taskContextBlock(target))

        \(Self.taskActionsContract)

        === CAPABILITIES ===
        You can query the database to find related messages, threads, and people involved.

        === DATABASE ===
        Database: \(dbPath)
        \(schema)

        === WORKSPACE ===
        Slack team ID: \(teamID)
        Slack web domain: \(domain).slack.com

        === QUERY TIPS ===
        - Always SELECT m.thread_ts alongside m.ts so you can build correct links for threaded messages.
        - Find messages by text or people involved:
          SELECT m.text, u.display_name, m.ts, m.thread_ts, m.channel_id FROM messages m
          JOIN users u ON m.user_id = u.id
          WHERE m.text LIKE '%keyword%'
          ORDER BY m.ts_unix DESC LIMIT 20

        === LINKING RULES ===
        ALWAYS use markdown links with descriptive text in the user's language. Never output bare URLs.

        Channel link:
          [#channel-name](slack://channel?team=\(teamID)&id={channel_id})

        Message link (top-level message, thread_ts is NULL or empty):
          [описательный текст](slack://channel?team=\(teamID)&id={channel_id}&message={ts})

        Message link inside a thread — use thread_ts (the parent's ts), NOT the reply's ts:
          [описательный текст](slack://channel?team=\(teamID)&id={channel_id}&message={thread_ts})

        Web permalink (only when the user explicitly asks for an https link):
          Top-level:     https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}
          Thread reply:  https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}?thread_ts={thread_ts}&cid={channel_id}
          Remove the dot from ts: 1740577800.000100 → p1740577800000100

        Rules:
        - Every referenced message MUST have a link
        - Link text describes WHAT is linked, not "link" or "click here"
        - Always SELECT channel_id, ts, AND thread_ts when fetching messages so you can build correct links
        - NEVER link to a channel when the user asked for a specific message — resolve the actual ts first

        === RESPONSE STYLE ===
        - Be concise and direct
        - Match the user's language
        - Use markdown for readability
        """
    }
}
