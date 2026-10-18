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
@MainActor
@Observable
package final class ChatTurnDriver {
    package static let flushInterval: TimeInterval = 1

    package private(set) var liveTurn: LiveTurn?
    package private(set) var sessionID: String?
    package private(set) var lastSessionError: ChatSessionError?
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
    @ObservationIgnored private let store: ChatTurnStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastFlush = Date.distantPast
    /// False once the session's prompt is stale (`stopRecordingSession`).
    @ObservationIgnored private var recordsSession = true
    @ObservationIgnored private let writes = SerialWrites()

    package init(
        conversationID: Int64,
        projectID: Int64? = nil,
        store: ChatTurnStore,
        clock: @escaping () -> Date = Date.init
    ) {
        self.conversationID = conversationID
        self.projectID = projectID
        self.store = store
        self.clock = clock
    }

    /// Starts tracking a turn whose assistant row (`messageID`) already
    /// exists. Regenerate/edit pass the NEW row and turn id.
    @discardableResult
    package func begin(messageID: Int64, turnID: String) -> LiveTurn {
        let turn = LiveTurn(messageID: messageID, turnID: turnID, startedAt: clock())
        liveTurn = turn
        lastFlush = .distantPast
        return turn
    }

    package func apply(_ event: ChatEvent) {
        switch event {
        case let .sessionReady(sid, _, _):
            recordSession(sid)
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

    private func recordSession(_ sid: String?) {
        guard recordsSession, let sid, !sid.isEmpty, sid != sessionID else { return }
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
    private func persist(_ turn: LiveTurn, _ write: @escaping @MainActor () async throws -> Void) {
        writes.start {
            do {
                try await write()
            } catch {
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
            finalizePersist(turn, status: "error", failure: failure)
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
        let (store, conversationID, text, usage) = (store, conversationID, turn.fullText, turn.usage)
        writes.start { [weak self] in
            do {
                try await store.finalizeTurn(conversationID: conversationID, messageID: turn.messageID, text: text,
                                             status: status, usage: usage, error: failure)
            } catch {
                turn.persistError = "Couldn't finalize the reply: \(error.localizedDescription)"
            }
            guard let self else { return }
            if self.liveTurn === turn { self.liveTurn = nil }
            self.isFinishing = false
            self.onTurnFinished?(turn)
        }
    }
}
