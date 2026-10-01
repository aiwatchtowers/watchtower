import Foundation
import Observation

/// Keeps a queued owner message across an app restart: it comes back as an
/// unsent draft in that chat's composer.
@MainActor
package protocol EmbeddedDraftMirror: AnyObject {
    func save(_ text: String, for key: EmbeddedChatKey)
    func clear(for key: EmbeddedChatKey)
    func restore(for key: EmbeddedChatKey) -> String?
}

/// One embedded chat's turns: `watchtower ai query` per turn through
/// `AIServiceProtocol`, the streamed text in an isolated `LiveTurn` (only the
/// live row re-renders), rows in an `EmbeddedChatStore`. Owned by
/// `EmbeddedChatCenter`, never by a view, so a turn keeps streaming and
/// persisting when its screen goes away.
///
/// Turn order (spec §4): the owner row and the reply's `partial` placeholder
/// are written before the process starts; text is flushed at most once per
/// `flushInterval`; the turn ends exactly once — `complete` (then
/// `spec.postTurn`), `partial` (Stop, quit) or `error` (with the real text).
@MainActor
@Observable
package final class EmbeddedChatEngine {
    package static let flushInterval: TimeInterval = 1
    package static let emptyReplyMessage = "The assistant returned no text."

    package enum TurnOutcome: Equatable {
        case completed(messageID: Int64, result: ChatPostTurnResult)
        case stopped(messageID: Int64)
        case failed(messageID: Int64, message: String)
    }

    package let spec: ChatSurfaceSpec
    /// Finished rows plus the running reply's placeholder (the view swaps
    /// that one for `LiveAssistantRow`). Never touched by a delta.
    package private(set) var messages: [ChatThreadItem] = []
    package private(set) var liveTurn: LiveTurn?
    /// The owner text of a turn waiting for a free slot; nil when none (or
    /// when the waiting turn is a follow-up with no owner text).
    package private(set) var queuedText: String?
    package private(set) var isQueued = false
    /// Survives navigation along with the engine.
    package var draft = ""
    /// A failure not tied to a row (history load, a send that could not be
    /// saved, a deleted context).
    package private(set) var bannerError: String?
    /// What `postTurn` made of each completed reply, for the view's slots.
    package private(set) var postTurnResults: [Int64: ChatPostTurnResult] = [:]
    /// The latest turn failed (or came back empty): Retry may rerun it.
    package private(set) var canRetry = false

    @ObservationIgnored package var onTurnFinished: ((TurnOutcome) -> Void)?

    package var isStreaming: Bool { liveTurn != nil }
    package var isBusy: Bool { isStreaming || isQueued }

    @ObservationIgnored private let store: EmbeddedChatStore
    @ObservationIgnored private let aiService: any AIServiceProtocol
    @ObservationIgnored private let gate: EmbeddedStreamGate
    @ObservationIgnored private let draftMirror: EmbeddedDraftMirror?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var running: RunningTurn?
    @ObservationIgnored private var pending: TurnRequest?
    @ObservationIgnored private var lastRequest: TurnRequest?
    /// Follow-up prompts produced while a turn was busy: flushed as one turn
    /// when it ends, or carried by the next owner turn.
    @ObservationIgnored private var queuedFollowUps: [String] = []
    /// Set by `shutdown(quietly: true)`: a deleted context's write errors
    /// have no screen to go to.
    @ObservationIgnored private var isQuiet = false

    private struct TurnRequest {
        let slot = UUID()
        /// The owner row to write; nil for follow-ups, hidden prompts and retries.
        let ownerText: String?
        let promptText: String
        let previousOwnerMessageAt: Date?
    }

    private struct RunningTurn {
        let request: TurnRequest
        let turn: LiveTurn
        var lastFlush: Date
        var stopRequested = false
        var failure: EmbeddedChatErrorClassifier.Failure?
    }

    package init(
        spec: ChatSurfaceSpec,
        store: EmbeddedChatStore,
        aiService: any AIServiceProtocol,
        gate: EmbeddedStreamGate,
        draftMirror: EmbeddedDraftMirror? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.spec = spec
        self.store = store
        self.aiService = aiService
        self.gate = gate
        self.draftMirror = draftMirror
        self.clock = clock
        do {
            sessionID = try store.loadSessionID()
            try reload()
        } catch {
            bannerError = "Couldn't load this chat: \(error.localizedDescription)"
        }
        if let restored = draftMirror?.restore(for: spec.key) { draft = restored }
    }

    // MARK: - Commands

    /// Sends the composer's text as an owner turn. Returns false (and keeps
    /// the text) when nothing was started or queued.
    @discardableResult
    package func sendDraft() -> Bool {
        let text = draft
        draft = ""
        guard send(text) else {
            draft = text
            return false
        }
        return true
    }

    /// An owner turn. Ignored while a turn is busy.
    @discardableResult
    package func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return false }
        let carried = queuedFollowUps.joined(separator: "\n")
        queuedFollowUps.removeAll()
        let prompt = carried.isEmpty ? trimmed : "\(carried)\n\n\(trimmed)"
        let previous = messages.last { $0.message.isUser }?.message.createdDate
        start(TurnRequest(ownerText: trimmed, promptText: prompt, previousOwnerMessageAt: previous))
        return true
    }

    /// A turn the owner did not type (an approved action's outcome): the
    /// optional notice is shown first as a system row; while a turn is busy
    /// the prompt waits for it to end.
    package func sendFollowUp(prompt: String, notice: String? = nil) {
        if let notice { appendRow(role: "system", text: notice) }
        guard !isBusy else {
            queuedFollowUps.append(prompt)
            return
        }
        start(TurnRequest(ownerText: nil, promptText: prompt, previousOwnerMessageAt: nil))
    }

    /// A turn with no visible owner row (onboarding's opening prompt).
    package func sendHidden(_ prompt: String) {
        guard !isBusy else { return }
        start(TurnRequest(ownerText: nil, promptText: prompt, previousOwnerMessageAt: nil))
    }

    /// A scripted row with no AI call (a questionnaire bubble, a greeting).
    package func appendLocal(role: String, text: String) {
        appendRow(role: role, text: text)
    }

    /// Stops the running turn (its text stays, as `partial`) or withdraws a
    /// queued one (its text goes back to the composer).
    package func stop() {
        if isQueued {
            cancelQueued()
            return
        }
        guard var current = running else { return }
        current.stopRequested = true
        running = current
        streamTask?.cancel()
        finish(current)
    }

    package func cancelQueued() {
        guard let request = pending else { return }
        gate.cancel(request.slot)
        pending = nil
        isQueued = false
        queuedText = nil
        if let text = request.ownerText {
            draft = draft.isEmpty ? text : "\(text)\n\(draft)"
        }
        draftMirror?.clear(for: spec.key)
    }

    /// Reruns the failed latest turn under a new reply row; the owner row is
    /// never written twice.
    package func retry() {
        guard canRetry, !isBusy, let last = lastRequest else { return }
        start(TurnRequest(ownerText: nil, promptText: last.promptText,
                          previousOwnerMessageAt: last.previousOwnerMessageAt))
    }

    /// Re-reads the rows (another surface wrote to the conversation).
    package func refresh() {
        guard !isStreaming else { return }
        refreshRows()
    }

    /// App quit: a running reply keeps what streamed, as `partial`.
    package func finishAsPartial() {
        guard var current = running else { return }
        current.stopRequested = true
        running = current
        streamTask?.cancel()
        finish(current)
    }

    /// The center lets go of the engine. `quietly`: its context was deleted,
    /// so write errors have nowhere to be shown.
    package func shutdown(quietly: Bool) {
        isQuiet = quietly
        cancelQueued()
        queuedFollowUps.removeAll()
        finishAsPartial()
    }

    // MARK: - Turn lifecycle

    private func start(_ request: TurnRequest) {
        canRetry = false
        if gate.tryAcquire(request.slot) {
            begin(request)
            return
        }
        pending = request
        isQueued = true
        queuedText = request.ownerText
        if let text = request.ownerText { draftMirror?.save(text, for: spec.key) }
        gate.enqueue(request.slot) { [weak self] in self?.dequeued(request) }
    }

    private func dequeued(_ request: TurnRequest) {
        guard let pending, pending.slot == request.slot else {
            gate.release(request.slot)
            return
        }
        self.pending = nil
        isQueued = false
        queuedText = nil
        begin(request)
    }

    private func begin(_ request: TurnRequest) {
        if request.ownerText != nil { draftMirror?.clear(for: spec.key) }
        let turnID = UUID().uuidString
        let ids: (ownerID: Int64?, assistantID: Int64)
        do {
            ids = try store.beginTurn(ownerText: request.ownerText, turnID: turnID)
        } catch {
            // Nothing was sent: the owner's text goes back to the composer.
            gate.release(request.slot)
            if let text = request.ownerText { draft = draft.isEmpty ? text : "\(text)\n\(draft)" }
            report(error, prefix: "Couldn't send")
            return
        }
        bannerError = nil
        lastRequest = request
        let turn = LiveTurn(messageID: ids.assistantID, turnID: turnID, startedAt: clock())
        liveTurn = turn
        running = RunningTurn(request: request, turn: turn, lastFlush: clock())
        refreshRows()

        let input = ChatTurnInput(text: request.promptText, isResumed: sessionID != nil,
                                  previousOwnerMessageAt: request.previousOwnerMessageAt, turnID: turnID)
        let stream = aiService.stream(
            prompt: spec.turnPrompt(input),
            systemPrompt: sessionID == nil ? spec.systemPrompt() : nil,
            sessionID: sessionID,
            dbPath: store.dbPath,
            model: nil,  // nil = the provider's resolved strong-tier model
            provider: nil,
            toolMode: spec.toolAccess.toolMode(key: spec.key, turnID: turnID)
        )
        streamTask = Task { [weak self] in
            await self?.consume(stream, turn: turn)
        }
    }

    private func consume(_ stream: AsyncThrowingStream<StreamEvent, Error>, turn: LiveTurn) async {
        var reducer = EmbeddedStreamReducer()
        do {
            for try await event in stream {
                guard isCurrent(turn) else { return }
                switch reducer.apply(event) {
                case .text(let text):
                    turn.replaceText(text, now: clock())
                    flushIfDue(turn)
                case .sessionID(let sid):
                    recordSession(sid)
                case .failed(let message):
                    running?.failure = EmbeddedChatErrorClassifier.classify(message: message)
                case .none:
                    break
                }
            }
        } catch {
            if isCurrent(turn), !Task.isCancelled {
                running?.failure = EmbeddedChatErrorClassifier.classify(error)
            }
        }
        guard isCurrent(turn), let current = running else { return }
        finish(current)
    }

    private func isCurrent(_ turn: LiveTurn) -> Bool {
        running?.turn === turn
    }

    private func flushIfDue(_ turn: LiveTurn) {
        guard let current = running, clock().timeIntervalSince(current.lastFlush) >= Self.flushInterval else { return }
        running?.lastFlush = clock()
        do {
            try store.saveProgress(messageID: turn.messageID, text: turn.fullText)
        } catch {
            // A turn whose text cannot be saved is not a successful turn.
            running?.failure = .init(code: .internalError, message: "Couldn't save the reply: \(error.localizedDescription)")
            streamTask?.cancel()
            finish(running ?? current)
        }
    }

    private func recordSession(_ sid: String) {
        guard !sid.isEmpty, sid != sessionID else { return }
        sessionID = sid
        do {
            try store.saveSessionID(sid)
        } catch {
            report(error, prefix: "Couldn't save the session")
        }
    }

    /// Ends the running turn exactly once.
    private func finish(_ current: RunningTurn) {
        guard running?.turn === current.turn else { return }
        running = nil
        streamTask = nil
        let turn = current.turn
        let text = turn.fullText
        let outcome: TurnOutcome
        if current.stopRequested {
            turn.finish(.interrupted, at: clock())
            persistFinal(turn, text: text, status: "partial", failure: nil)
            outcome = .stopped(messageID: turn.messageID)
        } else if let failure = current.failure ?? emptyReplyFailure(text) {
            let sessionError = ChatSessionError(turnID: turn.turnID, code: failure.code ?? .internalError,
                                                message: failure.message, retryable: true)
            turn.finish(.failed(sessionError), at: clock())
            persistFinal(turn, text: text, status: "error", failure: failure)
            outcome = .failed(messageID: turn.messageID, message: failure.message)
        } else {
            let result = spec.postTurn(ChatPostTurnInput(reply: text, turnID: turn.turnID, messageID: turn.messageID))
            turn.finish(.complete, at: clock())
            persistFinal(turn, text: result.displayText, status: "complete", failure: nil)
            for notice in result.notices { appendRow(role: "system", text: notice, reloading: false) }
            postTurnResults[turn.messageID] = result
            outcome = .completed(messageID: turn.messageID, result: result)
        }
        liveTurn = nil
        gate.release(current.request.slot)
        if case .failed = outcome { canRetry = true }
        refreshRows()
        onTurnFinished?(outcome)
        if case .stopped = outcome { return }
        flushFollowUps()
    }

    private func emptyReplyFailure(_ text: String) -> EmbeddedChatErrorClassifier.Failure? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .init(code: nil, message: Self.emptyReplyMessage) : nil
    }

    private func persistFinal(
        _ turn: LiveTurn,
        text: String,
        status: String,
        failure: EmbeddedChatErrorClassifier.Failure?
    ) {
        do {
            try store.finalize(messageID: turn.messageID, text: text, status: status,
                               errorCode: failure.map { ($0.code ?? .internalError).rawValue },
                               errorMessage: failure?.message)
        } catch {
            report(error, prefix: "Couldn't save the reply")
        }
    }

    private func flushFollowUps() {
        guard !queuedFollowUps.isEmpty, !isBusy else { return }
        let prompt = queuedFollowUps.joined(separator: "\n")
        queuedFollowUps.removeAll()
        start(TurnRequest(ownerText: nil, promptText: prompt, previousOwnerMessageAt: nil))
    }

    // MARK: - Rows

    private func appendRow(role: String, text: String, reloading: Bool = true) {
        do {
            try store.append(role: role, text: text)
            if reloading { try reload() }
        } catch {
            report(error, prefix: "Couldn't save the message")
        }
    }

    private func refreshRows() {
        do { try reload() } catch { report(error, prefix: "Couldn't load this chat") }
    }

    private func reload() throws {
        messages = try store.loadMessages().map {
            ChatThreadItem(message: $0, steps: [], siblingIndex: 1, siblingCount: 1)
        }
    }

    private func report(_ error: Error, prefix: String) {
        if isQuiet { return }
        if error is ChatContextGoneError {
            bannerError = ChatContextGoneError().localizedDescription
        } else {
            bannerError = "\(prefix): \(error.localizedDescription)"
        }
    }
}
