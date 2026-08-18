import Foundation
import GRDB
import WatchtowerCore

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

    /// Stable identity for a dictation targetID — the target is always
    /// persisted by the time this VM exists.
    var targetID: Int { target.id }

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
        aiService: (any AIServiceProtocol)? = nil
    ) {
        self.target = target
        self.viewModel = viewModel
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()

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

        // On the first turn the target context is in the system prompt. On a
        // resumed turn the CLI uses --resume and drops the system prompt entirely
        // — and if that session has expired (e.g. after an app restart) the model
        // would have NO context at all. So carry the live target context AND the
        // action contract with the message on every resumed turn: the assistant
        // never loses track of which target it is working on, sees the target's
        // current state, and can still emit valid watchtower-action blocks.
        let effectivePrompt = currentSessionID == nil
            ? text
            : "\(Self.taskContextBlock(target))\n\n\(Self.taskActionsContract)\n\n\(text)"

        var fullText = ""
        var streamFailed = false
        do {
            let stream = aiService.stream(
                prompt: effectivePrompt,
                systemPrompt: systemPrompt,
                sessionID: currentSessionID,
                dbPath: dbPath,
                model: nil  // nil = the provider's resolved strong-tier model
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
        do {
            try dbManager.dbPool.write { db in
                try ChatMessageQueries.insert(
                    db, conversationID: conversationID, role: "assistant", text: text
                )
                try ChatConversationQueries.touch(db, id: conversationID)
            }
        } catch {
            print("TargetChat: failed to persist assistant response for conversation \(conversationID): \(error)")
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
        do {
            try dbManager.dbPool.write { db in
                _ = try ChatMessageQueries.insert(
                    db, conversationID: conversationID, role: role, text: text
                )
            }
        } catch {
            print("TargetChat: failed to persist \(role) message for conversation \(conversationID): \(error)")
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
        do {
            try dbManager.dbPool.write { db in
                try ChatConversationQueries.updateSessionID(
                    db, id: conversationID, sessionID: sessionID
                )
            }
        } catch {
            print("TargetChat: failed to persist session id for conversation \(conversationID): \(error)")
        }
    }

    /// The action contract injected into the system prompt. Lists the
    /// supported watchtower-action types and their required fields; the AI
    /// emits these instead of writing to the DB. Kept as a constant so
    /// buildSystemPrompt stays focused on task/workspace context.
    nonisolated static let taskActionsContract = """
    === HOW TASKS WORK HERE ===
    A "task" in this app is a Watchtower TARGET — a row in the `targets` table,
    shown in the app's Targets list. You are NOT Claude Code; there is no
    "TaskCreate" and no separate Claude Code task list. The ONLY tasks that exist
    are Watchtower targets. Targets DO support a parent→child hierarchy:
    - create_child_target makes a NEW target that is a real CHILD of THIS task
      (it sets parent_id = this task) — that is exactly how you make a sub-task.
      It shows up nested under this task in the list. This is FULLY supported.
    - add_sub_item adds a lightweight checklist item (a "checkpoint") INSIDE this
      task — not a separate task, just a tick-box on this one.
    - link_target connects two existing targets with a typed relation (blocks etc.).
    So "convert sub-items into sub-tasks" = emit one create_child_target per item.

    === TASK ACTIONS ===
    Creating or changing tasks works ONLY through the blocks below. You have NO
    todo list and NO task tool — never use any built-in to-do/task/sub-agent tool,
    and never claim a task or sub-task "was created": it exists only after the user
    approves the card. To create or change anything, output a fenced block exactly like:
    ```watchtower-action
    { "type": "<action>", ...fields, "reason": "<why>" }
    ```
    One JSON object per block, and ONE block PER item — to create 8 sub-tasks emit
    8 create_child_target blocks. Do NOT write to the database directly.
    After emitting block(s), STOP and wait — do NOT assume anything was applied.
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

    JSON RULES (strict — a malformed block is dropped, not applied):
    - Emit ONE valid JSON object per block. Inside string values, escape every
      double quote as \\" and every backslash as \\\\.
    - Keep each string value on a single line — never put a raw line break inside
      a string (use \\n if you truly need one).
    - No trailing commas, no comments, no markdown inside the block.
    - Numbers (progress, target_id) are JSON numbers, not quoted strings.
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

    /// The `=== WATCH ACTIVITY ===` context block: recent events surfaced by the
    /// target's watches, so the assistant can act on them. Empty string when the
    /// target has no watch activity (the block is then omitted from the prompt).
    nonisolated static func watchActivityBlock(target: Target, dbPool: DatabasePool) -> String {
        let events = (try? dbPool.read { db in
            try TrackEventQueries.fetchForTarget(db, targetID: target.id, limit: 20)
        }) ?? []
        guard !events.isEmpty else { return "" }
        let eventLines = events.map { e -> String in
            let action = e.decodedAction.map { " [proposed: \($0.type.rawValue)]" } ?? ""
            return "- \(e.summary)\(action)"
        }
        let lines = eventLines.joined(separator: "\n")
        return """

        === WATCH ACTIVITY ===
        Recent updates surfaced by this target's watches (newest first). You may
        propose target mutations based on these via the task actions above.
        \(lines)
        """
    }

    /// This target's subjects for the MEMORY block: every track linked via
    /// `tracks.linked_target_id = target.id` (unfiltered by origin/dismissed —
    /// unlike TrackQueries.fetchByLinkedTarget, which is scoped to custom
    /// watches for a different UI feature), each contributing the same
    /// channels/participants/scalars TrackChatViewModel.trackMemorySubjects
    /// extracts, unioned, plus the target's own "target:<id>" mirror alias
    /// (mirroring Go's targetSubjects prepend). A bare target with no linked
    /// track yields just its own mirror alias.
    nonisolated static func targetMemorySubjects(target: Target, dbPool: DatabasePool) -> [String] {
        var subjects = Set<String>()
        subjects.insert("target:\(target.id)")
        let linkedTracks = (try? dbPool.read { db in
            try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE linked_target_id = ?", arguments: [target.id])
        }) ?? []
        for track in linkedTracks {
            for subject in TrackChatViewModel.trackMemorySubjects(track: track) where subject != "track:\(track.id)" {
                subjects.insert(subject)
            }
        }
        return Array(subjects)
    }

    nonisolated static func buildSystemPrompt(
        target: Target,
        dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir(),
        skillsDir: String? = SkillsCatalog.defaultDir()
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

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — same pattern as
        // SituationChatViewModel/TrackChatViewModel.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: targetMemorySubjects(target: target, dbPool: dbPool), dbPool: dbPool)
              ) + "\n\n"
            : ""

        // Persona skills (assistant surface): nil when no enabled skill
        // matches, so a workspace with no skills keeps a byte-identical prompt.
        let skillsSuffix = SkillsCatalog.promptBlock(persona: .assistant, dir: skillsDir)
            .map { "\n\n" + $0 } ?? ""

        return """
        You are Watchtower, an AI assistant helping the user make progress on a specific \
        task (target) tracked in their workspace.

        \(Self.taskContextBlock(target))
        \(Self.watchActivityBlock(target: target, dbPool: dbPool))

        \(memoryBlock)\(Self.taskActionsContract)

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
        - Always SELECT channel_id, ts, AND thread_ts when fetching messages so you can build correct links
        - NEVER link to a channel when the user asked for a specific message — resolve the actual ts first

        === RESPONSE STYLE ===
        - Be concise and direct
        - Match the user's language
        - Use markdown for readability
        """ + skillsSuffix
    }
}
