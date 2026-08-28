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

extension Array where Element == TargetActionCard {
    /// One-line composition summary for the collapsed batch block, grouped by
    /// action kind in first-appearance order: "9× check off · 21× edit".
    var batchBreakdown: String {
        var order: [TargetActionKind] = []
        var counts: [TargetActionKind: Int] = [:]
        for card in self {
            if counts[card.action.type] == nil { order.append(card.action.type) }
            counts[card.action.type, default: 0] += 1
        }
        return order.map { "\(counts[$0] ?? 0)× \($0.batchLabel)" }.joined(separator: " · ")
    }

    /// "1 pending · 2 applied · 1 failed" once any card is decided; nil while
    /// the whole batch is still pending (a fresh batch's default state).
    var batchStateSummary: String? {
        var pending = 0, applied = 0, failed = 0, rejected = 0
        for card in self {
            switch card.state {
            case .pending: pending += 1
            case .applied: applied += 1
            case .failed: failed += 1
            case .rejected: rejected += 1
            }
        }
        guard pending != count else { return nil }
        var parts: [String] = []
        if pending > 0 { parts.append("\(pending) pending") }
        if applied > 0 { parts.append("\(applied) applied") }
        if failed > 0 { parts.append("\(failed) failed") }
        if rejected > 0 { parts.append("\(rejected) rejected") }
        return parts.joined(separator: " · ")
    }
}

extension TargetActionKind {
    /// Short noun for the batch breakdown line.
    var batchLabel: String {
        switch self {
        case .updateStatus: "status change"
        case .updateNotes: "note"
        case .updateProgress: "progress update"
        case .addSubItem: "new checkpoint"
        case .createChildTarget: "new sub-task"
        case .linkTarget: "link"
        case .toggleSubItem: "check off"
        case .editSubItem: "edit"
        case .deleteSubItem: "deletion"
        case .setSubItemDue: "item due date"
        case .updateDueDate: "due date"
        case .updatePriority: "priority"
        case .updateBallOn: "ball-on"
        case .updateTitle: "rename"
        case .updateIntent: "context update"
        case .addLabel: "new label"
        case .removeLabel: "label removal"
        }
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
    // Cancelled by stop() (main actor) — the container calls it on tab close
    // and on container eviction; there is no deinit touching this.
    private var observationTask: Task<Void, Never>?

    /// Follow-ups produced by a decision taken while a turn was still streaming.
    /// The write applies immediately; its message waits here until the running
    /// turn ends (or the user sends the next one) so it is never dropped.
    private var queuedFollowUps: [String] = []

    /// Called after the chat did something that counts as activity on the target:
    /// an applied action or a finished turn. The host screen uses it to re-read the
    /// target row (a daemon-written next step included) and re-derive its
    /// next-step staleness badge. Never fires an AI call by itself; nil by default.
    var onTargetActivity: (() -> Void)?

    /// Called with the text of a user turn the moment it is sent. The tab
    /// container uses it to auto-title a brand-new tab from its first message.
    /// Only real user turns fire it — action follow-ups and system notices do
    /// not. Never fires an AI call by itself; nil by default.
    var onUserMessage: ((String) -> Void)?

    /// Cards still awaiting a decision — drives the "Approve all" affordance.
    var pendingActionCount: Int {
        actionCards.filter { $0.state == .pending }.count
    }

    /// `conversationID` is the tab this VM speaks into. Finding or creating it is
    /// the container's job (`TargetAssistantViewModel` owns the target's tab
    /// list), so this VM only ever adopts a conversation that already exists.
    init(
        target: Target,
        viewModel: TargetsViewModel,
        dbManager: DatabaseManager,
        conversationID: Int64,
        aiService: (any AIServiceProtocol)? = nil
    ) {
        self.target = target
        self.viewModel = viewModel
        self.dbManager = dbManager
        self.aiService = aiService ?? WatchtowerAIService()

        loadConversation(id: conversationID)
        startMessageObservation()
    }

    /// Tears the VM's long-lived work down: the GRDB message observation and any
    /// running turn. Called by the container when a tab is closed and when the
    /// center evicts the whole container — a `@MainActor deinit` cannot touch
    /// these tasks (the `CustomTrackTimelineViewModel.stop()` precedent), and
    /// without it the observation would keep the pool observed forever.
    func stop() {
        observationTask?.cancel()
        observationTask = nil
        streamTask?.cancel()
        streamTask = nil
    }

    /// Adopt the conversation the container resolved for this tab. A row that
    /// vanished (closed from another surface) surfaces as an error rather than
    /// silently starting a second, unpersisted thread.
    private func loadConversation(id: Int64) {
        do {
            guard let conversation = try dbManager.dbPool.read({ db in
                try ChatConversationQueries.fetchByID(db, id: id)
            }) else {
                errorMessage = "This chat no longer exists."
                return
            }
            let records = try dbManager.dbPool.read { db in
                try ChatMessageQueries.fetchByConversation(db, conversationID: id)
            }
            conversationID = conversation.id
            sessionID = conversation.sessionID
            messages = records.map { $0.toChatMessage() }
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
                    // A vanished VM ends the observation — `continue` would keep
                    // the pool observed for the process's lifetime.
                    guard let self else { break }
                    guard !self.isStreaming else { continue }
                    // Only adopt a snapshot that has MORE messages than we hold:
                    // observation events are delivered asynchronously, so right
                    // after a stream ends a stale snapshot (written mid-run) can
                    // arrive and must not clobber the fresher in-memory tail
                    // (e.g. the just-appended run summary).
                    if records.count > self.messages.count {
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

        // This VM is cached per target in an app-wide container and holds a
        // `Target` VALUE, while the detail view around it is itself a mutation
        // site (checklist drag-reorder, inline edits) — so the snapshot the
        // prompt renders has to be re-read per turn. Sending a stale checklist
        // is not cosmetic: the model addresses sub-items by index + text, and
        // both are re-checked against the live list at apply time.
        reloadTarget()

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
        onUserMessage?(text)

        messages.append(ChatMessage(
            id: UUID(),
            role: .assistant,
            text: "",
            timestamp: Date(),
            isStreaming: true
        ))
        startStream(prompt: prependQueuedFollowUps(to: text))
    }

    /// Feed a follow-up turn back into the conversation. The text is shown as a
    /// system message right away; when a turn is already streaming the prompt is
    /// queued instead of being dropped, and goes out at the next flush point.
    private func sendFollowUp(_ text: String) {
        appendSystemMessage(text)
        guard !isStreaming else {
            queuedFollowUps.append(text)
            return
        }
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))
        startStream(prompt: text)
    }

    /// Drain the queue into `text`, so a decision taken mid-stream still reaches
    /// the assistant even when the turn it was queued behind was cancelled.
    private func prependQueuedFollowUps(to text: String) -> String {
        guard !queuedFollowUps.isEmpty else { return text }
        let queued = queuedFollowUps.joined(separator: "\n")
        queuedFollowUps.removeAll()
        return "\(queued)\n\n\(text)"
    }

    /// Send everything queued during the finished turn as ONE follow-up turn.
    /// The system messages were already appended when the decisions were taken.
    private func flushQueuedFollowUps() {
        guard !queuedFollowUps.isEmpty, !isStreaming else { return }
        let prompt = queuedFollowUps.joined(separator: "\n")
        queuedFollowUps.removeAll()
        messages.append(ChatMessage(
            id: UUID(), role: .assistant, text: "", timestamp: Date(), isStreaming: true
        ))
        startStream(prompt: prompt)
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
            : "\(Self.taskContextBlock(target))\n\(Self.taskTreeBlock(target: target, dbPool: dbPool))\n\n"
                + "\(Self.taskActionsContract)\n\n\(text)"

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
            // A user-cancelled stream is not a failure — persist nothing for it.
            // A real failure lands in the transcript as a system message so a
            // reloaded conversation still shows that the run died (spec §7).
            if !Task.isCancelled {
                errorMessage = error.localizedDescription
                appendSystemMessage("⚠️ The assistant run failed: \(error.localizedDescription)")
            }
        }

        // On a failed OR cancelled stream, do NOT parse actions out of partial,
        // possibly-truncated output — that could surface a half-formed proposal
        // or auto-apply a half-streamed directive. Cancellation must be checked
        // explicitly: cancelling the consuming task makes the AsyncThrowingStream
        // end WITHOUT throwing, so the loop above exits cleanly. cancelStream()
        // has already persisted the partial assistant text; parsing here would
        // also persist it a second time.
        if streamFailed || Task.isCancelled {
            finishStream()
            return
        }

        let surfaced = surfaceActions(from: fullText)

        // Persist the assistant turn BEFORE the run summary / warnings, so the
        // reloaded transcript reads in the same order the run happened.
        if !surfaced.displayText.isEmpty, let convID = conversationID {
            Self.persistResponse(dbManager: dbManager, conversationID: convID, text: surfaced.displayText)
        }
        for text in surfaced.systemMessages {
            appendSystemMessage(text)
        }

        finishStream()
    }

    /// Parses watchtower-action blocks out of the assistant's final text,
    /// surfaces a card per action, and auto-applies execute-mode actions (an
    /// explicit owner directive) through the same apply core the Approve
    /// button uses — no per-action follow-up AI turn.
    /// Propose-mode actions stay pending and await Approve.
    /// Returns the visible prose for the assistant turn plus the system-message
    /// texts (one apply-run summary + a warning per malformed block) that the
    /// caller appends AFTER persisting the assistant turn, keeping the
    /// transcript in assistant-then-system order.
    private func surfaceActions(from fullText: String) -> (displayText: String, systemMessages: [String]) {
        let parsed = TargetActionParser.parse(fullText)
        // When the AI emits only an action block, visible prose is empty; show a
        // placeholder so the turn isn't blank and gets persisted into the transcript.
        let displayText = parsed.text.isEmpty && !parsed.actions.isEmpty
            ? "(proposed \(parsed.actions.count) action(s))"
            : parsed.text
        updateLastMessage(displayText)

        let assistantMessageID = messages.indices.last.map { messages[$0].id } ?? UUID()
        var appliedSummaries: [String] = []
        var failedSummaries: [String] = []
        var heldForApproval = 0
        for action in parsed.actions {
            actionCards.append(TargetActionCard(
                messageID: assistantMessageID, action: action, state: .pending
            ))
            if action.isExecute && !action.autoApplies(inChatFor: target.id) {
                heldForApproval += 1
            }
            guard action.autoApplies(inChatFor: target.id) else { continue }
            switch applyAction(action, cardIndex: actionCards.count - 1) {
            case .success(let summary):
                appliedSummaries.append(summary)
            case .failure(let error):
                failedSummaries.append("\(action.type.rawValue): \(error.localizedDescription)")
            }
        }
        if !appliedSummaries.isEmpty || !failedSummaries.isEmpty {
            // Execute-mode writes are target activity too — same contract as
            // the Approve paths, one ping per run.
            onTargetActivity?()
        }
        var systemMessages: [String] = []
        if !appliedSummaries.isEmpty || !failedSummaries.isEmpty {
            var parts: [String] = []
            if !appliedSummaries.isEmpty {
                parts.append("Applied: " + appliedSummaries.joined(separator: "; "))
            }
            if !failedSummaries.isEmpty {
                parts.append("Failed: " + failedSummaries.joined(separator: "; "))
            }
            systemMessages.append(parts.joined(separator: ". "))
        }
        if heldForApproval > 0 {
            // The reply may well claim the write was made. This message is what
            // the OWNER reads instead — like the Applied/Failed summary next to
            // it, it never reaches the model (a resumed turn carries the context
            // blocks and the contract, not transcript rows); what keeps the
            // model honest is the MODE rule in taskActionsContract.
            // Worded as "not applied automatically" rather than promising an
            // Approve: an action addressed outside the vertical line is held
            // here too, and approving that one fails at resolveActionTarget.
            systemMessages.append(
                "\(heldForApproval) change(s) aimed at another task were NOT applied " +
                "automatically — decide on their cards."
            )
        }
        for err in parsed.errors {
            systemMessages.append("⚠️ Invalid action proposal: \(err)")
        }
        return (displayText, systemMessages)
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
        switch applyAction(action, cardIndex: idx) {
        case .success(let summary):
            sendFollowUp("Action applied: \(summary). Continue with the task.")
        case .failure(let error):
            sendFollowUp("Action FAILED: \(error.localizedDescription). " +
                         "Do NOT assume it was applied; suggest how to proceed.")
        }
        // A decided action is target activity whether or not the write stuck —
        // the host screen must re-derive its staleness badge either way.
        onTargetActivity?()
    }

    /// Shared apply core for the Approve button and execute-mode auto-apply:
    /// reload the target (so the executor sees fresh state), apply through
    /// TargetActionExecutor, transition the card at `idx` to .applied/.failed,
    /// and reload again so the chat context stays current. The caller decides
    /// what (if anything) is fed back into the conversation.
    private func applyAction(_ action: ProposedAction, cardIndex idx: Int) -> Result<String, Error> {
        reloadTarget()
        do {
            let applyTarget = try resolveActionTarget(action)
            var summary = try TargetActionExecutor.apply(action, target: applyTarget, viewModel: viewModel)
            if applyTarget.id != target.id { summary += " [in task #\(applyTarget.id)]" }
            actionCards[idx].state = .applied(summary)
            reloadTarget()
            return .success(summary)
        } catch {
            actionCards[idx].state = .failed(error.localizedDescription)
            return .failure(error)
        }
    }

    /// Approve every pending card in one pass. Approving them one by one costs a
    /// full AI turn each (the follow-up restarts the stream), so a batch of 20-odd
    /// proposals is applied here as 20 writes and reported in a single follow-up.
    /// The AI's proposed kind is kept for each card — the per-card checkpoint /
    /// sub-task override stays a per-card decision.
    /// `messageID` scopes the pass to one turn's batch (the inline "Approve all"
    /// row above a batch of cards); nil approves every pending card in the chat.
    /// Above this many cards, the batch follow-up switches from an itemized
    /// list to a bare count (failures stay itemized).
    nonisolated static let compactBatchThreshold = 8

    func approveAll(messageID: UUID? = nil) {
        let pendingIDs = actionCards
            .filter { $0.state == .pending && (messageID == nil || $0.messageID == messageID) }
            .map(\.id)
        guard !pendingIDs.isEmpty else { return }
        reloadTarget()

        var applied: [String] = []
        var failed: [String] = []
        for cardID in pendingIDs {
            guard let idx = actionCards.firstIndex(where: { $0.id == cardID }) else { continue }
            do {
                let applyTarget = try resolveActionTarget(actionCards[idx].action)
                var summary = try TargetActionExecutor.apply(
                    actionCards[idx].action, target: applyTarget, viewModel: viewModel
                )
                if applyTarget.id != target.id { summary += " [in task #\(applyTarget.id)]" }
                actionCards[idx].state = .applied(summary)
                applied.append(summary)
            } catch {
                actionCards[idx].state = .failed(error.localizedDescription)
                failed.append(error.localizedDescription)
            }
            // Unconditionally: the actions rewrite whole JSON columns (sub-items),
            // so the next one must read back what this one wrote — including when
            // apply threw only AFTER its write landed.
            reloadTarget()
        }

        var parts: [String] = []
        if !applied.isEmpty {
            // A big batch's follow-up lands in the transcript and in the AI's
            // context verbatim — report a count, not dozens of item summaries.
            // Failures below stay itemized whatever the batch size.
            parts.append(pendingIDs.count > Self.compactBatchThreshold
                ? "Actions applied (\(applied.count) of \(pendingIDs.count))."
                : "Actions applied (\(applied.count)): \(applied.joined(separator: "; ")).")
        }
        if !failed.isEmpty {
            parts.append("Actions FAILED (\(failed.count)): \(failed.joined(separator: "; ")). " +
                         "Do NOT assume they were applied.")
        }
        parts.append("Continue with the task.")
        sendFollowUp(parts.joined(separator: " "))
        onTargetActivity?()
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
            priority: action.priority, targetId: action.targetId, relation: action.relation,
            index: action.index, match: action.match, done: action.done,
            dueDate: action.dueDate, ballOn: action.ballOn,
            mode: action.mode
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
        onTargetActivity?()
        flushQueuedFollowUps()
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

    /// Resolves which target an approved action applies to. An action carrying
    /// "target_id" may address any task in the current task's vertical line —
    /// its descendants or its parent chain (TargetTreeScope) — fetched fresh
    /// from the DB at apply time. Everything else applies to the current task.
    /// link_target's target_id is the link's other endpoint, not an address.
    private func resolveActionTarget(_ action: ProposedAction) throws -> Target {
        guard action.type != .linkTarget,
              let addressedID = action.targetId,
              addressedID != target.id else { return target }
        let (addressed, parents) = try dbManager.dbPool.read { db -> (Target?, [Int: Int?]) in
            var parents: [Int: Int?] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, parent_id FROM targets") {
                let id: Int = row["id"]
                parents[id] = row["parent_id"] as Int?
            }
            return (try TargetQueries.fetchByID(db, id: addressedID), parents)
        }
        guard let addressed,
              TargetTreeScope.isInScope(addressed: addressedID, current: target.id, parents: parents) else {
            throw TargetActionError.writeFailed(
                "task #\(addressedID) is not in this task's tree — only this task, " +
                "its sub-tasks, or its parents can be addressed"
            )
        }
        return addressed
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
    todo list and NO task tool — never use any built-in to-do/task/sub-agent tool.
    To create or change anything, output a fenced block exactly like:
    ```watchtower-action
    { "type": "<action>", ...fields, "reason": "<why>" }
    ```
    One JSON object per block, and ONE block PER item — to create 8 sub-tasks emit
    8 create_child_target blocks. Do NOT write to the database directly.
    Supported actions and required fields:
    - update_status      { "status": "todo|in_progress|blocked|done|dismissed|snoozed" }
    - update_notes       { "note": "<text to append>" }
    - update_progress    { "progress": <0-100 integer> }
    - update_priority    { "priority": "high|medium|low" }
    - update_due_date    { "due_date": "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM", "" clears }
    - update_ball_on     { "ball_on": "<who the ball is on>", "" clears }
    - add_sub_item       { "text": "<sub-item text>" }
    - toggle_sub_item    { "index": <N>, "match": "<current text>", "done": true|false }
    - edit_sub_item      { "index": <N>, "match": "<current text>", "text": "<new text>" }
    - delete_sub_item    { "index": <N>, "match": "<current text>" }
    - set_sub_item_due   { "index": <N>, "match": "<current text>", "due_date": "YYYY-MM-DD", "" clears }
    - create_child_target{ "text": "<title>", "intent": "<goal>", "priority": "high|medium|low" }
    - link_target        { "target_id": <id of an EXISTING target>, "relation": "contributes_to|blocks|related|duplicates" }
    - update_title       { "text": "<new task title>" }
    - update_intent      { "text": "<the task's goal/context, replaces the current intent>" }
    - add_label          { "text": "<label>" } — adds one label (free-form tag) to the task
    - remove_label       { "text": "<label>" } — removes that label from the task
    Every block must also include "reason".
    Labels are free-form tags the owner filters the Targets list by (the task's
    current ones are in the Labels line). One block per label; adding an existing
    label is a no-op. Prefer a label the owner already uses (LABELS IN USE, when
    listed) over coining a near-duplicate.
    For the *_sub_item actions, "index" is the #N shown next to the item in the
    addressed task's sub-items list (the CURRENT TASK by default) and "match" is
    that item's EXACT current text — both are required and are re-checked at
    apply time, so never guess either.
    To PROMOTE an existing sub-item into a real sub-task, emit create_child_target
    with the item's text, then delete_sub_item for that item.
    For link_target, first resolve the other target's id with the list_targets /
    get_target tools; never guess an id.

    ADDRESSING OTHER TASKS IN THIS TASK'S TREE (optional "target_id"):
    Every action except link_target also accepts "target_id": <id> — the task
    the action applies to. Omitted = the CURRENT task. It may ONLY address this
    task's own vertical line: its sub-tasks at any depth or its parent chain
    (both listed in TASK TREE), plus sub-tasks created during this conversation
    — their id is echoed back as "created child target #N". The apply step
    re-checks this scope and fails the card for any other task, so never
    address a sibling or unrelated task.
    For create_child_target, "target_id" is the PARENT the new sub-task is
    created under — that is how you build deeper levels of the tree.
    For the *_sub_item actions on another task, only address a sub-items list
    you have actually seen (in TASK TREE or a get_target lookup) — never guess.

    MODE — propose vs execute:
    Every action block may carry an optional "mode" field: "propose" (the default
    when absent) or "execute".
    - "mode":"execute" — use it when the owner's message is an explicit
      instruction (imperative: "break this down", "set the deadline", "gather
      the Jira data"). Execute-mode actions on the CURRENT task are applied
      immediately, and your reply MUST report what was done (e.g. "Done:
      created 4 sub-tasks and set the due date"). If any action in the reply
      addresses another task, say that part is waiting for approval instead of
      reporting it as done.
    - "mode":"propose" (or no mode) — use it when the owner is discussing or
      thinking aloud. Propose-mode actions become cards awaiting the owner's
      approval. In propose mode never claim a task or change "was made" — it
      exists only after the owner approves the card; after emitting the
      block(s), STOP and wait, and do NOT assume anything was applied.
    - When the message is ambiguous, propose.
    - An action carrying a "target_id" other than the CURRENT task is ALWAYS a
      proposal: the owner approves every write that leaves this chat's own task,
      so "mode":"execute" is ignored there and the card waits for approval.

    MANDATE — broad powers, narrow mandate:
    Within a directive you may modify this task's vertical line — the task
    itself, its sub-tasks at any depth and its parent chain (title, intent,
    priority, due date, status, notes, labels, sub-items, child targets) — but only what
    the directive implies. Findings beyond the mandate (sibling branches, other
    people's blockers) go into your prose reply, NEVER into actions. Never emit
    actions the owner did not ask for, and never create targets outside this
    task's vertical line.

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
        let subItemsList = target.decodedSubItems.enumerated()
            .map { i, item in
                var due = ""
                if let d = item.dueDate, !d.isEmpty { due = " (due \(d))" }
                return "- [\(item.done ? "x" : " ")] #\(i) \(item.text)\(due)"
            }
            .joined(separator: "\n")
        let subItemsText = subItemsList.isEmpty ? "(none)" : subItemsList
        let labels = target.decodedTags.joined(separator: ", ")
        return """
        === CURRENT TASK ===
        ID: \(target.id)
        Text: \(target.text)
        Intent: \(target.intent)
        Status: \(target.status)
        Priority: \(target.priority)
        Labels: \(labels.isEmpty ? "(none)" : labels)
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

    /// The `=== LABELS IN USE ===` block: the workspace's existing label
    /// vocabulary, so the assistant reuses the owner's labels instead of
    /// coining near-duplicates. Empty string when no labels exist (block
    /// omitted, byte-identical prompt — the watchActivityBlock shape).
    nonisolated static func labelsInUseBlock(dbPool: DatabasePool) -> String {
        let tags = (try? dbPool.read { db in try TargetQueries.fetchDistinctTags(db) }) ?? []
        guard !tags.isEmpty else { return "" }
        return """

        === LABELS IN USE ===
        \(tags.joined(separator: ", "))
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

    /// The `=== TASK TREE ===` context block: the current task's parent chain
    /// and its sub-task tree (each sub-task with its checklist), so the
    /// assistant can address them with "target_id". Empty string when the task
    /// has neither a parent nor sub-tasks (the block is then omitted).
    nonisolated static func taskTreeBlock(target: Target, dbPool: DatabasePool) -> String {
        let all = (try? dbPool.read { db in
            try Target.fetchAll(db, sql: "SELECT * FROM targets")
        }) ?? []
        let byID = Dictionary(all.map { ($0.id, $0) }) { first, _ in first }
        var childrenOf: [Int: [Target]] = [:]
        for t in all {
            if let parent = t.parentId { childrenOf[parent, default: []].append(t) }
        }

        // Parent chain, nearest first. Visited guards against parent_id cycles.
        var ancestors: [Target] = []
        var visited: Set<Int> = [target.id]
        var cursor = target.parentId
        while let pid = cursor, visited.insert(pid).inserted, let parent = byID[pid] {
            ancestors.append(parent)
            cursor = parent.parentId
        }

        // Descendants, depth-first (same cycle guard via `seen`).
        var flat: [(depth: Int, node: Target)] = []
        var seen: Set<Int> = [target.id]
        func walk(_ parentID: Int, depth: Int) {
            for child in childrenOf[parentID] ?? [] where seen.insert(child.id).inserted {
                flat.append((depth, child))
                walk(child.id, depth: depth + 1)
            }
        }
        walk(target.id, depth: 0)

        guard !ancestors.isEmpty || !flat.isEmpty else { return "" }

        func describe(_ t: Target) -> String {
            "#\(t.id) \"\(t.text)\" (\(t.status), \(Int((t.progress * 100).rounded()))%)"
        }
        var lines: [String] = []
        if !ancestors.isEmpty {
            lines.append("Parents (nearest first):")
            lines.append(contentsOf: ancestors.map { "- \(describe($0))" })
        }
        if !flat.isEmpty {
            lines.append("Sub-tasks (with their sub-items):")
            // Cap so a huge tree cannot flood the prompt; the cut is reported.
            let cap = 50
            for (depth, node) in flat.prefix(cap) {
                let indent = String(repeating: "  ", count: depth)
                lines.append("\(indent)- \(describe(node))")
                for (i, item) in node.decodedSubItems.enumerated() {
                    var due = ""
                    if let d = item.dueDate, !d.isEmpty { due = " (due \(d))" }
                    lines.append("\(indent)    - [\(item.done ? "x" : " ")] #\(i) \(item.text)\(due)")
                }
            }
            if flat.count > cap { lines.append("(… \(flat.count - cap) more sub-tasks omitted)") }
        }
        return """

        === TASK TREE ===
        Tasks you may also act on with "target_id" (this task's parents and sub-tasks):
        \(lines.joined(separator: "\n"))
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

        // Assistant skills: whether this surface lists them comes from its
        // context_type via SkillsCatalog.chatContextTypes, and the block is
        // nil when no enabled skill matches, so a workspace with no skills
        // keeps a byte-identical prompt.
        let skillsSuffix = SkillsCatalog.promptBlock(contextType: "target", dir: skillsDir)
            .map { "\n\n" + $0 } ?? ""

        return """
        You are Watchtower, an AI assistant helping the user make progress on a specific \
        task (target) tracked in their workspace.

        \(Self.taskContextBlock(target))
        \(Self.taskTreeBlock(target: target, dbPool: dbPool))
        \(Self.watchActivityBlock(target: target, dbPool: dbPool))\(Self.labelsInUseBlock(dbPool: dbPool))

        \(memoryBlock)\(Self.taskActionsContract)

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        You have read-only tools over the user's OWN local Watchtower database. \
        Use them to look things up instead of asking the user:
        - list_messages — search/list the user's Slack messages by person, channel, and/or keyword, \
        newest first. This is how you check what happened in Slack (it is already synced locally).
        - list_targets / get_target — other targets and their links (resolve ids for link_target here).
        - get_person / list_people — people cards; list_tracks / list_digests / list_jira_issues — work context.
        - list_transcripts / get_transcript — recorded meeting transcripts.
        \(ChatViewModel.noLiveSourcesRule)

        === WORKSPACE ===
        Slack team ID: \(teamID)
        Slack web domain: \(domain).slack.com

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
        - NEVER link to a channel when the user asked for a specific message — resolve the actual ts first

        === RESPONSE STYLE ===
        - Be concise and direct
        - Match the user's language
        - Use markdown for readability
        """ + skillsSuffix
    }
}
