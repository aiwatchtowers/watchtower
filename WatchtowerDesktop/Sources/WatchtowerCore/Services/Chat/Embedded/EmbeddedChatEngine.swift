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
/// A store write that fails during a turn fails the turn (a failed write of
/// a notice after a saved reply only raises the banner).
///
/// Every store write is queued (`writes`), in the order it was asked for,
/// and awaits the writer off the main thread (board #670): a turn's rows
/// are written before its process starts (`isStarting` meanwhile — the
/// composer takes no second send and nothing can stop it yet), and an ended
/// turn stays live, no longer stoppable, until its final state landed
/// (`isFinishing`).
///
/// Follow-up prompts (an approved action's outcome) wait while a turn is
/// busy and run after it completes. Those waiting behind a stopped turn ride
/// the next owner turn or follow-up; after a failed turn (its own carried
/// follow-ups included), Retry or the next owner turn.
/// They are never dropped while the engine lives.
@MainActor
@Observable
package final class EmbeddedChatEngine {
    package static let flushInterval: TimeInterval = 1
    package static let emptyReplyMessage = "The assistant returned no text."

    package enum TurnOutcome: Equatable {
        case completed(messageID: Int64, result: ChatPostTurnResult)
        case stopped(messageID: Int64)
        case failed(messageID: Int64, message: String)
        /// The turn never started: its rows could not be written (the text
        /// went back to the composer).
        case notStarted(message: String)
    }

    /// Replaced by `EmbeddedChatCenter.engine(for:)` whenever a surface asks
    /// again, so the prompt and postTurn closures always see that surface's
    /// current state (its key never changes).
    @ObservationIgnored package private(set) var spec: ChatSurfaceSpec
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
    /// saved, a deleted context). Cleared by the next turn that completes.
    package private(set) var bannerError: String?
    /// What `postTurn` made of each completed reply, for the view's slots.
    package private(set) var postTurnResults: [Int64: ChatPostTurnResult] = [:]
    /// The latest turn failed on the provider's side: Retry may rerun it.
    package private(set) var canRetry = false

    @ObservationIgnored package var onTurnFinished: ((TurnOutcome) -> Void)?

    package var isStreaming: Bool { liveTurn != nil }
    /// The turn ended and its final state is being written — for a reply
    /// that streamed to its end, `postTurn` acts on it first (board #670: an
    /// action surface's writes await the writer). Nothing can stop it any
    /// more — Stop is disabled — and it ends by itself once its writes
    /// landed (`finished()`).
    package var isFinishing: Bool { finishing != nil }
    /// `postTurn` is acting on a reply that streamed to its end: the
    /// composer says its changes are being applied.
    package private(set) var isApplyingChanges = false
    /// The turn's end being written (and its `postTurn`).
    private var finishing: Task<Void, Never>?
    /// A turn's rows are being written; its process starts once they landed.
    package private(set) var isStarting = false
    package var isBusy: Bool { isStreaming || isQueued || isStarting }
    /// Busy, or holding follow-ups for a later turn — the center keeps such
    /// an engine even when no view has shown it for a while.
    package var hasPendingWork: Bool { isBusy || !queuedFollowUps.isEmpty }

    @ObservationIgnored private let store: EmbeddedChatStore
    @ObservationIgnored private let aiService: any AIServiceProtocol
    @ObservationIgnored private let gate: EmbeddedStreamGate
    @ObservationIgnored private let draftMirror: EmbeddedDraftMirror?
    @ObservationIgnored private let provider: String?
    @ObservationIgnored private let inactivityTimeout: TimeInterval
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var sessionID: String?
    /// The history could not be read: sending would start a fresh provider
    /// session over the stored one, so a send first retries the load.
    @ObservationIgnored private var loadFailed = false
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var running: RunningTurn?
    @ObservationIgnored private var pending: TurnRequest?
    @ObservationIgnored private var lastRequest: TurnRequest?
    /// What the latest failed turn had already applied; a Retry hands it to
    /// the surface. Lives here, not on a surface controller, because the
    /// engine (and its Retry) outlives the screen that made it.
    @ObservationIgnored private var appliedBeforeFailure: [ChatAppliedChange] = []
    @ObservationIgnored private var queuedFollowUps: [String] = []
    /// The latest turn ended in an error: new follow-ups wait for Retry or
    /// the next owner turn instead of running on the session that failed.
    @ObservationIgnored private var lastTurnFailed = false
    /// Set by `shutdown(quietly: true)`: a deleted context's "not found"
    /// writes have no screen to go to.
    @ObservationIgnored private var isQuiet = false
    /// Every store write, one after another in the order asked for.
    @ObservationIgnored private let writes = SerialWrites()
    /// The rows of the turn being started (`isStarting`).
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// A quit or a shutdown arrived while the turn's rows were written: the
    /// turn ends as stopped once they landed, and is never sent.
    @ObservationIgnored private var stopBeforeStart = false
    /// The app is quitting: a turn that ends from here on (its end awaits
    /// the writer, board #670) starts no follow-up turn.
    @ObservationIgnored private var isQuitting = false
    /// The session id being stored, so a repeated event stores it once.
    @ObservationIgnored private var savingSessionID: String?

    private struct TurnRequest {
        let slot = UUID()
        /// The owner row to write; nil for follow-ups, hidden prompts and retries.
        let ownerText: String?
        /// The owner's (or a hidden) prompt; nil for a follow-ups-only turn.
        let basePrompt: String?
        /// Follow-up prompts sent ahead of `basePrompt`, given back to the
        /// queue if the turn never starts or does not complete.
        let carriedFollowUps: [String]
        let previousOwnerMessageAt: Date?
        /// A Retry's `ChatTurnInput.alreadyApplied`; empty for every other turn.
        var alreadyApplied: [ChatAppliedChange] = []

        var promptText: String {
            let carried = carriedFollowUps.joined(separator: "\n")
            guard let basePrompt else { return carried }
            return carried.isEmpty ? basePrompt : "\(carried)\n\n\(basePrompt)"
        }
    }

    private struct RunningTurn {
        let request: TurnRequest
        let turn: LiveTurn
        /// The run's provider resumes sessions: only then is its session id
        /// kept (another provider's id is not Claude's to resume).
        let keepsSession: Bool
        var lastFlush: Date
        var lastEvent: Date
        /// The banner shown when the turn began: a completed turn clears it.
        let bannerAtBegin: String?
        var stopRequested = false
        var failure: EmbeddedChatErrorClassifier.Failure?
    }

    package init(
        spec: ChatSurfaceSpec,
        store: EmbeddedChatStore,
        aiService: any AIServiceProtocol,
        gate: EmbeddedStreamGate,
        draftMirror: EmbeddedDraftMirror? = nil,
        provider: String? = nil,
        // A turn that streams nothing this long ends as an error, so a hung
        // `ai query` cannot hold one of the app-wide slots for good.
        inactivityTimeout: TimeInterval = 600,
        clock: @escaping () -> Date = Date.init
    ) {
        self.spec = spec
        self.store = store
        self.aiService = aiService
        self.gate = gate
        self.draftMirror = draftMirror
        self.provider = provider
        self.inactivityTimeout = inactivityTimeout
        self.clock = clock
        loadHistory()
        if let restored = draftMirror?.restore(for: spec.key) {
            // Back in the composer: from here on it is an ordinary draft.
            draft = restored
            draftMirror?.clear(for: spec.key)
        }
    }

    // MARK: - Commands

    /// Sends the composer's text as an owner turn. Returns false (and keeps
    /// the text) when the text is empty, a turn is busy, or the history could
    /// not be read; true once the turn was handed on — it may still be queued,
    /// or fail to save, in which case the text comes back to the draft.
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
        guard !trimmed.isEmpty, !isBusy, historyLoaded(), spec.willSend(trimmed) else { return false }
        let previous = messages.last { $0.message.isUser }?.message.createdDate
        start(TurnRequest(ownerText: trimmed, basePrompt: trimmed, carriedFollowUps: takeFollowUps(),
                          previousOwnerMessageAt: previous))
        return true
    }

    /// A turn the owner did not type (an approved action's outcome): the
    /// optional notice is shown first as a system row; while a turn is busy
    /// the prompt waits for it to complete.
    package func sendFollowUp(prompt: String, notice: String? = nil) {
        if let notice { queueRow(role: "system", text: notice) }
        queuedFollowUps.append(prompt)
        // After a failed turn the follow-ups wait for Retry or the next owner turn.
        guard !isBusy, !lastTurnFailed, historyLoaded() else { return }
        startFollowUps()
    }

    /// A turn with no visible owner row (onboarding's opening prompt).
    package func sendHidden(_ prompt: String) {
        guard !isBusy, historyLoaded() else { return }
        start(TurnRequest(ownerText: nil, basePrompt: prompt, carriedFollowUps: [], previousOwnerMessageAt: nil))
    }

    /// A scripted row with no AI call (a questionnaire bubble, a greeting).
    package func appendLocal(role: String, text: String) {
        queueRow(role: role, text: text)
    }

    /// Stops the running turn (its text stays, as `partial`) or withdraws a
    /// queued one (its text goes back to the composer). A turn whose rows are
    /// being written, or whose end is, cannot be stopped (the composer's
    /// Stop is disabled meanwhile).
    package func stop() {
        if isQueued {
            cancelQueued()
            return
        }
        guard running != nil else { return }
        running?.stopRequested = true
        endRunningTurn()
    }

    package func cancelQueued() {
        guard let request = withdrawQueued() else { return }
        if let text = request.ownerText {
            draft = draft.isEmpty ? text : "\(text)\n\(draft)"
        }
        draftMirror?.clear(for: spec.key)
    }

    /// Reruns the failed latest turn under a new reply row, with every
    /// follow-up waiting since; the owner row is never written twice.
    package func retry() {
        guard canRetry, !isBusy, let last = lastRequest, spec.mayContinue() else { return }
        let request = TurnRequest(ownerText: nil, basePrompt: last.basePrompt, carriedFollowUps: takeFollowUps(),
                                  previousOwnerMessageAt: last.previousOwnerMessageAt,
                                  alreadyApplied: appliedBeforeFailure)
        guard !request.promptText.isEmpty else { return }
        start(request)
    }

    /// Returns once the turn being started has its rows written and its
    /// process started (or could not start): `isStreaming` then says which.
    package func started() async {
        await startTask?.value
    }

    /// Returns once a turn being started or finishing has ended, and every
    /// write queued so far landed: what a surface awaits before deleting the
    /// conversation under it, the quit, and tests.
    package func finished() async {
        await startTask?.value
        await finishing?.value
        await writes.idle()
    }

    /// Re-reads the rows (another surface wrote to the conversation).
    package func refresh() {
        guard !isStreaming else { return }
        refreshRows()
    }

    /// App quit, step 1: a queued turn never starts during termination. Its
    /// owner text stays in the draft mirror and comes back after a restart.
    package func abandonQueuedForQuit() {
        isQuitting = true
        _ = withdrawQueued()
    }

    /// App quit, step 2: a running reply keeps what streamed, as `partial`.
    /// One whose rows are being written ends as stopped once they landed.
    package func finishAsPartial() {
        if isStarting { stopBeforeStart = true }
        guard running != nil else { return }
        running?.stopRequested = true
        endRunningTurn()
    }

    /// The center lets go of the engine. `quietly`: its context was deleted,
    /// so "not found" write errors have nowhere to be shown.
    package func shutdown(quietly: Bool) {
        isQuiet = quietly
        cancelQueued()
        finishAsPartial()
        if !queuedFollowUps.isEmpty {
            log("dropping \(queuedFollowUps.count) follow-up(s) on shutdown")
            queuedFollowUps.removeAll()
        }
    }

    /// The chat's context is gone (a deleted task): decisions waiting for a
    /// later turn will never be sent, so they stop holding the engine.
    package func discardFollowUps(reason: String) {
        guard !queuedFollowUps.isEmpty else { return }
        log("dropping \(queuedFollowUps.count) follow-up(s): \(reason)")
        queuedFollowUps.removeAll()
    }

    /// The surface asked for its engine again (see `spec`).
    package func update(spec newSpec: ChatSurfaceSpec) {
        guard newSpec.key == spec.key else { return }
        spec = newSpec
    }

    // MARK: - Turn lifecycle

    private func start(_ request: TurnRequest) {
        if gate.tryAcquire(request.slot) {
            begin(request)
            return
        }
        pending = request
        isQueued = true
        queuedText = request.ownerText
        if let text = request.ownerText { draftMirror?.save(text, for: spec.key) }
        let gate = self.gate
        gate.enqueue(request.slot) { [weak self] in
            // An engine gone without `shutdown` must not keep the slot.
            guard let self else { return gate.release(request.slot) }
            self.dequeued(request)
        }
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

    /// Takes the queued turn back out of the gate; its follow-ups return to
    /// the queue. The caller decides where the owner text goes.
    private func withdrawQueued() -> TurnRequest? {
        guard let request = pending else { return nil }
        gate.cancel(request.slot)
        pending = nil
        isQueued = false
        queuedText = nil
        queuedFollowUps.insert(contentsOf: request.carriedFollowUps, at: 0)
        return request
    }

    private func begin(_ request: TurnRequest) {
        let turnID = UUID().uuidString
        let options = spec.runOptions()
        isStarting = true
        stopBeforeStart = false
        startTask = Task { [self] in
            await writeRowsAndStart(request, turnID: turnID, options: options)
            startTask = nil
        }
    }

    /// Writes the turn's rows, then starts its process.
    private func writeRowsAndStart(_ request: TurnRequest, turnID: String, options: ChatRunOptions) async {
        let store = self.store
        let provider = options.provider ?? self.provider
        let ids: (ownerID: Int64?, assistantID: Int64)
        do {
            ids = try await writes.runThrowing { [self] in
                // A provider that cannot resume the Claude session runs turns it
                // never sees: the session is forgotten, so the next Claude turn
                // starts fresh and its surface replays the whole conversation.
                if !options.resumesSession, sessionID != nil {
                    try await store.saveSessionID(nil)
                    sessionID = nil
                }
                return try await store.beginTurn(ownerText: request.ownerText, turnID: turnID, provider: provider)
            }
        } catch {
            isStarting = false
            // Nothing was sent: the owner's text goes back to the composer
            // (ahead of anything typed meanwhile), its follow-ups back to the queue.
            gate.release(request.slot)
            if let text = request.ownerText {
                draft = draft.isEmpty ? text : "\(text)\n\(draft)"
                draftMirror?.clear(for: spec.key)  // back in the composer: an ordinary draft
            }
            queuedFollowUps.insert(contentsOf: request.carriedFollowUps, at: 0)
            report(error, prefix: "Couldn't send")
            onTurnFinished?(.notStarted(message: "Couldn't send: \(error.localizedDescription)"))
            return
        }
        isStarting = false
        if request.ownerText != nil { draftMirror?.clear(for: spec.key) }
        canRetry = false
        lastRequest = request
        // Still applied if this turn fails before its postTurn runs.
        appliedBeforeFailure = request.alreadyApplied
        let now = clock()
        let turn = LiveTurn(messageID: ids.assistantID, turnID: turnID, startedAt: now)
        liveTurn = turn
        running = RunningTurn(request: request, turn: turn, keepsSession: options.resumesSession, lastFlush: now,
                              lastEvent: now, bannerAtBegin: bannerError)
        refreshRows()
        if stopBeforeStart {
            // A quit or a shutdown came first: nothing is sent, and the
            // follow-ups it carried never reached the provider.
            queuedFollowUps.insert(contentsOf: request.carriedFollowUps, at: 0)
            running?.stopRequested = true
            endRunningTurn()
            return
        }
        startStream(request, turn: turn, options: options)
    }

    private func startStream(_ request: TurnRequest, turn: LiveTurn, options: ChatRunOptions) {
        let resumed = options.resumesSession ? sessionID : nil
        let input = ChatTurnInput(text: request.promptText, isResumed: resumed != nil,
                                  previousOwnerMessageAt: request.previousOwnerMessageAt, turnID: turn.turnID,
                                  alreadyApplied: request.alreadyApplied)
        let stream = aiService.stream(
            prompt: spec.turnPrompt(input),
            systemPrompt: resumed == nil ? spec.systemPrompt() : nil,
            sessionID: resumed,
            dbPath: store.dbPath,
            model: options.model,  // nil = the provider's resolved strong-tier model
            provider: options.provider,
            toolMode: spec.toolAccess.toolMode(key: spec.key, turnID: turn.turnID),
            readFolder: options.readFolder
        )
        streamTask = Task { [weak self] in
            await self?.consume(stream, turn: turn)
        }
        startWatchdog(for: turn)
    }

    private func consume(_ stream: AsyncThrowingStream<StreamEvent, Error>, turn: LiveTurn) async {
        var reducer = EmbeddedStreamReducer()
        do {
            for try await event in stream {
                guard isCurrent(turn) else { return }
                running?.lastEvent = clock()
                switch reducer.apply(event) {
                case .text(let text):
                    turn.replaceText(text, now: clock())
                    flushIfDue(turn)
                case .sessionID(let sid):
                    if running?.keepsSession == true { recordSession(sid) }
                case .failed(let message):
                    fail(EmbeddedChatErrorClassifier.classify(message: message))
                case .none:
                    break
                }
            }
        } catch {
            if isCurrent(turn), !Task.isCancelled { fail(EmbeddedChatErrorClassifier.classify(error)) }
        }
        guard isCurrent(turn) else { return }
        endRunningTurn()
    }

    /// Records the turn's failure; the first one wins.
    private func fail(_ failure: EmbeddedChatErrorClassifier.Failure) {
        guard running != nil, running?.failure == nil else { return }
        running?.failure = failure
    }

    /// A store write failed mid-turn: the turn ends as an error now.
    private func failForStore(_ error: Error, prefix: String) {
        fail(.init(code: .internalError, message: "\(prefix): \(error.localizedDescription)", retryable: false))
        log("\(prefix): \(error)")
        endRunningTurn()
    }

    private func isCurrent(_ turn: LiveTurn) -> Bool {
        running?.turn === turn
    }

    private func startWatchdog(for turn: LiveTurn) {
        let interval = min(inactivityTimeout, 30)
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))  // a cancelled sleep ends the loop below
                guard let self, !Task.isCancelled, self.isCurrent(turn) else { return }
                self.checkInactivity()
            }
        }
    }

    /// Ends a turn that has streamed nothing for `inactivityTimeout`. Run by
    /// the watchdog; tests call it directly.
    package func checkInactivity() {
        guard let current = running, clock().timeIntervalSince(current.lastEvent) >= inactivityTimeout else { return }
        fail(.init(code: nil, message: "The assistant stopped responding (no output for "
                   + "\(Int(inactivityTimeout / 60)) min)."))
        endRunningTurn()
    }

    private func flushIfDue(_ turn: LiveTurn) {
        guard let current = running, clock().timeIntervalSince(current.lastFlush) >= Self.flushInterval else { return }
        running?.lastFlush = clock()
        let (store, text) = (store, turn.fullText)
        writes.start { [self] in
            do {
                try await store.saveProgress(messageID: turn.messageID, text: text)
            } catch {
                // Only the turn it was for, if it still runs.
                if isCurrent(turn) { failForStore(error, prefix: "Couldn't save the reply") }
            }
        }
    }

    private func recordSession(_ sid: String) {
        guard !sid.isEmpty, sid != sessionID, sid != savingSessionID, let turn = running?.turn else { return }
        savingSessionID = sid
        let store = store
        writes.start { [self] in
            do {
                try await store.saveSessionID(sid)
                sessionID = sid  // only once stored
            } catch {
                if isCurrent(turn) { failForStore(error, prefix: "Couldn't save the session") }
            }
            if savingSessionID == sid { savingSessionID = nil }
        }
    }

    /// Ends the running turn exactly once: cancels its stream and watchdog,
    /// writes its final state, frees its slot, then starts what waits.
    ///
    /// The final state awaits the writer (board #670), and a reply that
    /// streamed to its end runs the surface's `postTurn` first, which may
    /// await database writes too: until they landed, the turn is still live
    /// (`isStreaming`, `isFinishing`, its slot held) but no longer running,
    /// so Stop, a quit or a late stream event cannot end it a second time.
    private func endRunningTurn() {
        guard let current = running else { return }
        running = nil
        streamTask?.cancel()
        streamTask = nil
        watchdog?.cancel()
        watchdog = nil
        // A completed turn clears a banner older than itself; one raised while
        // it ran or ended (a notice or reload that failed) stays visible.
        let earlierBanner = bannerError
        bannerError = nil
        // Its own task: the stream's task that got here is cancelled.
        finishing = Task { [self] in
            let outcome: TurnOutcome
            switch await endNow(current) {
            case .ended(let ended):
                outcome = ended
            case .completed(let reply):
                isApplyingChanges = true
                outcome = await finalizeCompleted(current, reply: reply)
                isApplyingChanges = false
            }
            finishing = nil
            settle(current, outcome: outcome, earlierBanner: earlierBanner)
        }
    }

    /// The turn's end once its final state is written: the slot freed and
    /// what waits started.
    private func settle(_ current: RunningTurn, outcome: TurnOutcome, earlierBanner: String?) {
        liveTurn = nil
        gate.release(current.request.slot)
        refreshRows()
        switch outcome {
        case .completed:
            lastTurnFailed = false
            if bannerError == nil, earlierBanner != current.bannerAtBegin { bannerError = earlierBanner }
            startFollowUps()
        case .stopped:
            // Its prompt (follow-ups included) reached the provider already.
            lastTurnFailed = false
            if bannerError == nil { bannerError = earlierBanner }
        case .failed:
            lastTurnFailed = true
            if bannerError == nil { bannerError = earlierBanner }
            // Not delivered: the follow-ups wait for Retry or the next owner turn.
            queuedFollowUps.insert(contentsOf: current.request.carriedFollowUps, at: 0)
        case .notStarted:
            break  // never produced by a turn that ran
        }
        onTurnFinished?(outcome)
    }

    /// How a turn ends: now (stopped, failed, or a reply that could not be
    /// saved), or through `postTurn` with the reply on disk.
    private enum TurnEnd {
        case ended(TurnOutcome)
        case completed(reply: String)
    }

    private func endNow(_ current: RunningTurn) async -> TurnEnd {
        let turn = current.turn
        let text = turn.fullText
        if current.stopRequested {
            turn.finish(.interrupted, at: clock())
            await persistFinal(turn, text: text, status: "partial", failure: nil)
            return .ended(.stopped(messageID: turn.messageID))
        }
        if let failure = current.failure {
            return .ended(await failTurn(turn, text: text, failure: failure))
        }
        // The reply must be on disk before postTurn acts on it.
        let store = store
        do {
            try await writes.runThrowing { try await store.saveProgress(messageID: turn.messageID, text: text) }
        } catch {
            report(error, prefix: "Couldn't save the reply")
            return .ended(await failTurn(turn, text: text, failure: .init(
                code: .internalError, message: "Couldn't save the reply: \(error.localizedDescription)", retryable: false),
                persist: false))
        }
        return .completed(reply: text)
    }

    private func finalizeCompleted(_ current: RunningTurn, reply text: String) async -> TurnOutcome {
        let turn = current.turn
        let result = await spec.postTurn(ChatPostTurnInput(reply: text, turnID: turn.turnID, messageID: turn.messageID,
                                                           alreadyApplied: current.request.alreadyApplied))
        // An action surface may answer with tool proposals only and show a
        // placeholder; a reply that still has nothing to show is an error.
        if result.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return await failTurn(turn, text: text, failure: .init(code: nil, message: Self.emptyReplyMessage))
        }
        guard await persistFinal(turn, text: result.displayText, status: "complete", failure: nil) else {
            // The reply is not on disk: not a successful turn. What postTurn
            // already applied is named, so the owner knows it happened and a
            // Retry (which the surface tells not to repeat it) can follow.
            // A retried turn still owns what its earlier attempt applied,
            // whether or not this reply proposed it again.
            let carried = current.request.alreadyApplied.filter { old in !result.applied.contains { $0.key == old.key } }
            appliedBeforeFailure = carried + result.applied
            var message = bannerError ?? "Couldn't save the reply"
            if !appliedBeforeFailure.isEmpty {
                message += ". Already applied: " + appliedBeforeFailure.map(\.summary).joined(separator: "; ")
                    + " — Retry won't apply them again."
            }
            let marked = EmbeddedChatErrorClassifier.Failure(code: .internalError, message: message, retryable: true)
            if await !markFailedBestEffort(turn, text: text, failure: marked) {
                // The row stays `partial` on disk; Retry is only in memory.
                message += " The reply couldn't be marked failed either — retry now; Retry is gone once this chat is left for long."
            }
            bannerError = message
            return await failTurn(turn, text: text, failure: .init(code: .internalError, message: message, retryable: true),
                                  persist: false)
        }
        turn.finish(.complete, at: clock())
        for notice in result.notices {
            await writes.run { [self] in await appendRow(role: "system", text: notice, reloading: false) }
        }
        postTurnResults[turn.messageID] = result
        return .completed(messageID: turn.messageID, result: result)
    }

    /// One more try to record the error row (the save just failed — a
    /// transient lock may have cleared), so its card and Retry show.
    private func markFailedBestEffort(
        _ turn: LiveTurn,
        text: String,
        failure: EmbeddedChatErrorClassifier.Failure
    ) async -> Bool {
        let store = store
        do {
            try await writes.runThrowing {
                try await store.finalize(messageID: turn.messageID, text: text, status: "error",
                                         errorCode: (failure.code ?? .internalError).rawValue,
                                         errorMessage: failure.message)
            }
            return true
        } catch {
            log("the failed reply could not be marked either: \(error)")
            return false
        }
    }

    private func failTurn(
        _ turn: LiveTurn,
        text: String,
        failure: EmbeddedChatErrorClassifier.Failure,
        persist: Bool = true
    ) async -> TurnOutcome {
        let sessionError = ChatSessionError(turnID: turn.turnID, code: failure.code ?? .internalError,
                                            message: failure.message, retryable: failure.retryable)
        turn.finish(.failed(sessionError), at: clock())
        if persist { await persistFinal(turn, text: text, status: "error", failure: failure) }
        canRetry = failure.retryable
        return .failed(messageID: turn.messageID, message: failure.message)
    }

    @discardableResult
    private func persistFinal(
        _ turn: LiveTurn,
        text: String,
        status: String,
        failure: EmbeddedChatErrorClassifier.Failure?
    ) async -> Bool {
        let store = store
        let errorCode = failure.map { ($0.code ?? .internalError).rawValue }
        do {
            try await writes.runThrowing {
                try await store.finalize(messageID: turn.messageID, text: text, status: status,
                                         errorCode: errorCode, errorMessage: failure?.message)
            }
            return true
        } catch {
            report(error, prefix: "Couldn't save the reply")
            return false
        }
    }

    private func takeFollowUps() -> [String] {
        defer { queuedFollowUps.removeAll() }
        return queuedFollowUps
    }

    /// Queued follow-ups go out together as one turn — unless the surface
    /// says its context is gone (then they are dropped, with a log line).
    private func startFollowUps() {
        guard !queuedFollowUps.isEmpty, !isBusy, !isQuitting else { return }
        guard spec.mayContinue() else {
            log("dropping \(queuedFollowUps.count) follow-up(s): the chat's context is gone")
            queuedFollowUps.removeAll()
            return
        }
        let prompts = takeFollowUps()
        start(TurnRequest(ownerText: nil, basePrompt: nil, carriedFollowUps: prompts, previousOwnerMessageAt: nil))
    }

    // MARK: - Rows

    private func loadHistory() {
        do {
            sessionID = try store.loadSessionID()
            try reload()
            loadFailed = false
        } catch {
            loadFailed = true
            report(error, prefix: "Couldn't load this chat")
        }
    }

    /// True when the history (and its provider session) is known; retries a
    /// failed load first.
    private func historyLoaded() -> Bool {
        if loadFailed { loadHistory() }
        return !loadFailed
    }

    /// Queues a row behind the writes asked for before it.
    private func queueRow(role: String, text: String) {
        writes.start { [self] in await appendRow(role: role, text: text) }
    }

    /// Run inside `writes` only, so rows land in the order asked for.
    private func appendRow(role: String, text: String, reloading: Bool = true) async {
        do {
            try await store.append(role: role, text: text)
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

    /// Every failure is logged; the owner sees it unless the chat's context
    /// was deleted (`shutdown(quietly:)` swallows only "not found").
    private func report(_ error: Error, prefix: String) {
        log("\(prefix): \(error)")
        if error is ChatContextGoneError {
            if !isQuiet { bannerError = ChatContextGoneError().localizedDescription }
            return
        }
        bannerError = "\(prefix): \(error.localizedDescription)"
    }

    private func log(_ message: String) {
        NSLog("EmbeddedChatEngine[%@]: %@", spec.key.description, message)
    }
}
