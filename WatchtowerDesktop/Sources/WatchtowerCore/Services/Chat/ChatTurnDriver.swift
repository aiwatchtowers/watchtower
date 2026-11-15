import Foundation
import Observation

/// Folds a session's v2 events into the live turn AND the database. Owned by
/// the session client (app-lifetime, on the pool), never by a view model —
/// so a turn keeps persisting when the owner navigates away (CHAT-01).
///
/// Text is flushed to `chat_messages` at most once per `flushInterval` and
/// once more at the terminal event; tool steps are written as they happen
/// (CHAT-02). A turn ends exactly once: `turn_done`, a turn-scoped `error`,
/// or `finishRunningAsPartial` (stop watchdog, process death, eviction, quit).
///
/// Every write is queued as it happens, in order, and awaits the writer off
/// the main thread (board #670), so a write lock held by another process
/// never freezes the UI. An ended turn stays `liveTurn` (no longer running,
/// its full text still shown) while its terminal write is under way
/// (`isFinishing`); `onTurnFinished` fires once that write landed, so what a
/// reload reads is the turn's final state.
///
/// The turn's lease (spec 2026-11-15 §4.4, §5): while a turn runs, the
/// lease watch reads the lease every `leasePollInterval` — a cancel set by
/// the phone's Stop runs `onRemoteCancel` (the session's own Stop) — and
/// refreshes its heartbeat every `heartbeatInterval`. A heartbeat that finds
/// no lease, an update by message id that changes no row, or a foreign-key
/// failure means the conversation is gone: `onConversationGone` fires once
/// and the turn writes nothing more.
@MainActor
@Observable
package final class ChatTurnDriver {
    package static let flushInterval: TimeInterval = 1
    package static let heartbeatInterval: TimeInterval = 15
    package static let leasePollInterval: Duration = .seconds(1)

    package private(set) var liveTurn: LiveTurn?
    package private(set) var sessionID: String?
    package private(set) var actualProvider: String?
    package private(set) var actualModel: String?
    package private(set) var routing: ChatRoutingMetadata?
    /// The actual provider's capability row from its session_ready (nil
    /// until one names its provider).
    package private(set) var actualCapabilities: ProviderCapabilities?
    package private(set) var lastSessionError: ChatSessionError?
    /// An eager ready can fail before any turn exists. Keep the real storage
    /// cause observable until an actual-metadata write succeeds.
    package private(set) var actualPersistenceError: Error?
    package var actualPersistenceErrorMessage: String? {
        actualPersistenceError.map(Self.actualPersistenceMessage)
    }
    /// The turn ended and its terminal write is under way: the turn can no
    /// longer be stopped, and no next turn starts until it landed.
    package private(set) var isFinishing = false
    /// A turn is running or finishing.
    package var isBusy: Bool { liveTurn?.isRunning == true || isFinishing }

    @ObservationIgnored package let conversationID: Int64
    /// The chat project the session was spawned for: its session id is
    /// recorded only while the conversation is still in that project.
    @ObservationIgnored package let projectID: Int64?
    @ObservationIgnored package var onTurnFinished: ((LiveTurn) -> Void)?
    /// A step started waiting on this `agent_actions` row. The session
    /// subprocess wrote the row, which no app observation sees, so the
    /// action feeds re-read now — the card the step points at must exist
    /// while the turn is blocked on it, not at the turn's end.
    @ObservationIgnored package var onActionAwaited: ((Int64) -> Void)?
    /// The other device's Stop set the running turn's cancel: stop it as
    /// the owner's Stop does. Fires once per turn.
    @ObservationIgnored package var onRemoteCancel: (() -> Void)?
    /// The running turn's conversation is gone: cancel the turn. Fires once.
    @ObservationIgnored package var onConversationGone: (() -> Void)?
    /// The running turn's conversation went away under it; nothing more is written.
    @ObservationIgnored package private(set) var conversationGone = false
    @ObservationIgnored private let store: ChatTurnStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastFlush = Date.distantPast
    /// False once the session's prompt is stale (`stopRecordingSession`).
    @ObservationIgnored private var recordsSession = true
    @ObservationIgnored private let writes = SerialWrites()
    /// Waits one lease poll; nil: no lease watch runs (it is driven by
    /// `pollLease` alone).
    @ObservationIgnored private let leaseTick: (@Sendable () async throws -> Void)?
    @ObservationIgnored private var leaseWatch: Task<Void, Never>?
    @ObservationIgnored private var lastHeartbeat = Date.distantPast
    @ObservationIgnored private var remoteCancelHonoured = false

    package init(
        conversationID: Int64,
        projectID: Int64? = nil,
        store: ChatTurnStore,
        clock: @escaping () -> Date = Date.init,
        leaseTick: (@Sendable () async throws -> Void)? = { try await Task.sleep(for: ChatTurnDriver.leasePollInterval) }
    ) {
        self.conversationID = conversationID
        self.projectID = projectID
        self.store = store
        self.clock = clock
        self.leaseTick = leaseTick
    }

    /// Starts tracking a turn whose assistant row (`messageID`) already
    /// exists. Regenerate/edit pass the NEW row and turn id.
    @discardableResult
    package func begin(messageID: Int64, turnID: String) -> LiveTurn {
        let turn = LiveTurn(messageID: messageID, turnID: turnID, startedAt: clock())
        liveTurn = turn
        turn.persistError = actualPersistenceErrorMessage
        // Eager pinned/off hosts already reported their resolved actual model.
        // Automatic preflight hosts must report a new selection for this turn.
        if routing?.mode == "pinned" || routing?.reason == "fallback_disabled",
           let provider = actualProvider, let model = actualModel {
            recordActual(provider: provider, model: model, routing: routing)
        }
        lastFlush = .distantPast
        conversationGone = false
        remoteCancelHonoured = false
        lastHeartbeat = clock()
        startLeaseWatch()
        return turn
    }

    /// One lease poll of the running turn: honours a cancel the other
    /// device set, and refreshes the heartbeat once `heartbeatInterval`
    /// passed. The watch calls it every `leasePollInterval`.
    package func pollLease() async {
        guard let turn = liveTurn, turn.isRunning, !conversationGone else { return }
        let (store, conversationID, turnID) = (store, conversationID, turn.turnID)
        let now = clock()
        if now.timeIntervalSince(lastHeartbeat) >= Self.heartbeatInterval {
            lastHeartbeat = now
            do {
                let held = try await store.heartbeat(conversationID: conversationID, turnID: turnID,
                                                     nowMS: ChatLease.milliseconds(now))
                guard liveTurn === turn, turn.isRunning else { return }
                if !held {
                    conversationLost()
                    return
                }
            } catch {
                guard liveTurn === turn, turn.isRunning else { return }
                if ChatConversationGoneError.matches(error) {
                    conversationLost()
                    return
                }
                NSLog("ChatTurnDriver: chat lease heartbeat failed: %@", error.localizedDescription)
            }
        }
        do {
            let lease = try await store.lease(conversationID: conversationID)
            guard liveTurn === turn, turn.isRunning, !remoteCancelHonoured,
                  let lease, lease.turnID == turnID, lease.cancelRequestedAtMS != nil else { return }
            remoteCancelHonoured = true
            onRemoteCancel?()
        } catch {
            NSLog("ChatTurnDriver: reading the chat lease failed: %@", error.localizedDescription)
        }
    }

    package func apply(_ event: ChatEvent) {
        switch event {
        case let .sessionReady(sid, provider, model, routing, capabilities):
            recordSession(sid)
            recordActual(provider: provider, model: model, routing: routing)
            // A session_ready that names its provider replaces the row (nil
            // when it carries none: the catalog's row is read instead); the
            // routing placeholder names none and keeps it.
            if capabilities != nil || !provider.isEmpty { actualCapabilities = capabilities }
        case .turnStart:
            break
        case let .textDelta(turnID, text):
            guard let turn = running(turnID) else { return }
            turn.appendDelta(text, now: clock())
            flushIfDue(turn)
        case let .toolStart(start):
            stepStarted(start)
        case let .toolEnd(end):
            stepFinished(end)
        case let .toolWait(wait):
            stepWaiting(wait)
        case let .usage(usage):
            running(usage.turnID)?.setUsage(usage)
        case let .turnDone(turnID, status, sid):
            recordSession(sid)
            guard running(turnID) != nil else { return }
            finalize(status == .complete ? .complete : .interrupted)
        case let .error(error):
            handle(error)
        case .exited:
            finishRunningAsPartial()
        }
    }

    /// A session-level failure observed outside the event stream (the
    /// process died without a terminal event) — kept for the UI.
    package func noteSessionError(_ error: ChatSessionError) {
        lastSessionError = error
    }

    /// The project prompt this session was spawned with changed: its session
    /// id must never be stored again (the project write just cleared it), or
    /// a later turn would `--resume` the stale prompt.
    package func stopRecordingSession() {
        recordsSession = false
    }

    /// Forgets a turn that never reached a provider, without ending it: no
    /// write, no `onTurnFinished`. The caller must hand it to another session
    /// (`ChatSessionClient.surrenderHeldTurn`), whose driver begins it again —
    /// otherwise its row stays an empty `partial` forever.
    package func releaseUnsentTurn() {
        liveTurn = nil
    }

    /// Stop watchdog, process death, eviction, app quit: whatever was
    /// streamed stays, as `partial` (CHAT-01).
    package func finishRunningAsPartial() {
        finalize(.interrupted)
    }

    /// Returns once every write queued so far has landed: a closing session
    /// (quit, eviction) and tests await it.
    package func writesSettled() async {
        await writes.idle()
    }

    // MARK: - Private

    private func running(_ turnID: String) -> LiveTurn? {
        guard let turn = liveTurn, turn.isRunning, turn.turnID == turnID else { return nil }
        return turn
    }

    private func startLeaseWatch() {
        leaseWatch?.cancel()
        guard let leaseTick else { return }
        leaseWatch = Task { [weak self] in
            while !Task.isCancelled {
                do { try await leaseTick() } catch { return }
                guard let self, self.liveTurn?.isRunning == true else { return }
                await self.pollLease()
            }
        }
    }

    /// The conversation went away under the running turn: stop writing,
    /// and let the session cancel the turn.
    private func conversationLost() {
        guard !conversationGone else { return }
        conversationGone = true
        leaseWatch?.cancel()
        onConversationGone?()
    }

    private func recordActual(provider: String, model: String, routing: ChatRoutingMetadata?) {
        guard recordsSession, !conversationGone else { return }
        self.routing = routing
        guard !provider.isEmpty else { return }
        actualProvider = provider
        actualModel = model
        let (store, conversationID, projectID, turn) = (store, conversationID, projectID, liveTurn)
        writes.start { [weak self] in
            do {
                try await store.saveActual(conversationID: conversationID, messageID: turn?.messageID,
                                           provider: provider, model: model, routing: routing, projectID: projectID)
                guard let self else { return }
                let previous = self.actualPersistenceErrorMessage
                self.actualPersistenceError = nil
                if let previous {
                    if self.lastSessionError?.message == previous { self.lastSessionError = nil }
                    if turn?.persistError == previous { turn?.persistError = nil }
                    if self.liveTurn?.persistError == previous { self.liveTurn?.persistError = nil }
                }
            } catch {
                guard let self else { return }
                self.actualPersistenceError = error
                let message = Self.actualPersistenceMessage(error)
                self.lastSessionError = ChatSessionError(turnID: nil, code: .internalError, message: message, retryable: false)
                turn?.persistError = message
            }
        }
    }

    private static func actualPersistenceMessage(_ error: Error) -> String {
        "Couldn't save the actual provider: \(error.localizedDescription)"
    }

    private func recordSession(_ sid: String?) {
        guard recordsSession, !conversationGone, let sid, !sid.isEmpty, sid != sessionID else { return }
        sessionID = sid
        let turn = liveTurn
        let (store, conversationID, projectID) = (store, conversationID, projectID)
        writes.start {
            do {
                try await store.saveSessionID(conversationID: conversationID, sessionID: sid, projectID: projectID)
            } catch {
                turn?.persistError = "Couldn't save the session id: \(error.localizedDescription)"
            }
        }
    }

    private func stepStarted(_ start: ChatToolStart) {
        guard let turn = running(start.turnID) else { return }
        let now = clock()
        let seq = turn.startStep(start, at: now)
        let store = store
        persist(turn) { try await store.stepStarted(messageID: turn.messageID, seq: seq, start: start, at: now) }
    }

    private func stepFinished(_ end: ChatToolEnd) {
        guard let turn = running(end.turnID) else { return }
        let now = clock()
        turn.finishStep(end, at: now)
        let store = store
        persist(turn) { try await store.stepFinished(messageID: turn.messageID, end: end, at: now) }
        flush(turn, status: "partial", errorCode: nil)
    }

    /// Waiting is live only; a wait whose `tool_start` never arrived first
    /// persists a nameless start, so the call stays a visible step even if
    /// the turn ends before its `tool_end` (CHAT-02).
    private func stepWaiting(_ wait: ChatToolWait) {
        guard let turn = running(wait.turnID) else { return }
        if !turn.steps.contains(where: { $0.id == wait.id }) {
            stepStarted(ChatToolStart(turnID: wait.turnID, id: wait.id, name: "", argsJSON: "{}"))
        }
        let awaited = turn.waitingActionIDs
        turn.waitStep(wait)
        if !awaited.contains(wait.actionID), turn.waitingActionIDs.contains(wait.actionID) {
            onActionAwaited?(wait.actionID)
        }
    }

    /// A turn-scoped error for the running turn ends it; a session-level
    /// error (or one for a turn no longer running) is kept for the UI.
    private func handle(_ error: ChatSessionError) {
        guard let turn = liveTurn, turn.isRunning else {
            lastSessionError = error
            return
        }
        guard error.turnID == nil || error.turnID == turn.turnID else { return }
        finalize(.failed(error))
    }

    private func flushIfDue(_ turn: LiveTurn) {
        guard clock().timeIntervalSince(lastFlush) >= Self.flushInterval else { return }
        flush(turn, status: "partial", errorCode: nil)
    }

    private func flush(_ turn: LiveTurn, status: String, errorCode: String?) {
        lastFlush = clock()
        let (store, text, usage) = (store, turn.fullText, turn.usage)
        persist(turn) {
            try await store.saveProgress(messageID: turn.messageID, text: text, status: status,
                                         usage: usage, errorCode: errorCode)
        }
    }

    /// Queues `write` behind the ones asked for before it.
    /// Nothing runs once the conversation is gone, a write queued before
    /// that included.
    private func persist(_ turn: LiveTurn, _ write: @escaping @MainActor () async throws -> Void) {
        writes.start { [weak self] in
            guard self?.conversationGone != true else { return }
            do {
                try await write()
            } catch {
                if ChatConversationGoneError.matches(error) {
                    self?.conversationLost()
                    return
                }
                turn.persistError = "Couldn't save the reply: \(error.localizedDescription)"
            }
        }
    }

    private func finalize(_ phase: LiveTurn.Phase) {
        guard let turn = liveTurn, turn.isRunning else { return }
        turn.finish(phase, at: clock())
        switch phase {
        case .complete:
            finalizePersist(turn, status: "complete", failure: nil)
        case let .failed(failure):
            finalizePersist(turn, status: failure.persistenceCode == "quota_exhausted" && !turn.fullText.isEmpty ? "partial" : "error",
                            failure: failure)
        case .interrupted, .running:
            finalizePersist(turn, status: "partial", failure: nil)
        }
    }

    /// The terminal write: message state + `:::artifact` versions (CHAT-05
    /// storage side) commit together in one transaction (`ChatTurnStore.
    /// finalizeTurn`) — a crash or write failure can never leave one without
    /// the other. An errored turn writes no artifacts (the store skips the
    /// parse for `status == "error"`). The turn leaves `liveTurn`, and
    /// `onTurnFinished` fires, once it landed.
    private func finalizePersist(_ turn: LiveTurn, status: String, failure: ChatSessionError?) {
        lastFlush = clock()
        isFinishing = true
        leaseWatch?.cancel()
        let (store, conversationID, text, usage) = (store, conversationID, turn.fullText, turn.usage)
        writes.start { [weak self] in
            if self?.conversationGone != true {
                do {
                    // The lease is released in the same transaction.
                    try await store.finalizeTurn(conversationID: conversationID, messageID: turn.messageID, turnID: turn.turnID,
                                                 text: text, status: status, usage: usage, error: failure)
                } catch {
                    if ChatConversationGoneError.matches(error) {
                        self?.conversationLost()
                    } else {
                        turn.persistError = "Couldn't finalize the reply: \(error.localizedDescription)"
                    }
                }
            }
            guard let self else { return }
            if self.liveTurn === turn { self.liveTurn = nil }
            self.isFinishing = false
            self.onTurnFinished?(turn)
        }
    }
}
