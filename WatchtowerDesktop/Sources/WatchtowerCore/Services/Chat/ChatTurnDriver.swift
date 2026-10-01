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
@MainActor
@Observable
package final class ChatTurnDriver {
    package static let flushInterval: TimeInterval = 1

    package private(set) var liveTurn: LiveTurn?
    package private(set) var sessionID: String?
    package private(set) var lastSessionError: ChatSessionError?

    @ObservationIgnored package let conversationID: Int64
    /// The chat project the session was spawned for: its session id is
    /// recorded only while the conversation is still in that project.
    @ObservationIgnored package let projectID: Int64?
    @ObservationIgnored package var onTurnFinished: ((LiveTurn) -> Void)?
    @ObservationIgnored private let store: ChatTurnStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastFlush = Date.distantPast

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

    /// Stop watchdog, process death, eviction, app quit: whatever was
    /// streamed stays, as `partial` (CHAT-01).
    package func finishRunningAsPartial() {
        finalize(.interrupted)
    }

    // MARK: - Private

    private func running(_ turnID: String) -> LiveTurn? {
        guard let turn = liveTurn, turn.isRunning, turn.turnID == turnID else { return nil }
        return turn
    }

    private func recordSession(_ sid: String?) {
        guard let sid, !sid.isEmpty, sid != sessionID else { return }
        sessionID = sid
        do {
            try store.saveSessionID(conversationID: conversationID, sessionID: sid, projectID: projectID)
        } catch {
            liveTurn?.persistError = "Couldn't save the session id: \(error.localizedDescription)"
        }
    }

    private func stepStarted(_ start: ChatToolStart) {
        guard let turn = running(start.turnID) else { return }
        let now = clock()
        let seq = turn.startStep(start, at: now)
        persist(turn) { try store.stepStarted(messageID: turn.messageID, seq: seq, start: start, at: now) }
    }

    private func stepFinished(_ end: ChatToolEnd) {
        guard let turn = running(end.turnID) else { return }
        let now = clock()
        turn.finishStep(end, at: now)
        persist(turn) { try store.stepFinished(messageID: turn.messageID, end: end, at: now) }
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
        persist(turn) {
            try store.saveProgress(messageID: turn.messageID, text: turn.fullText, status: status,
                                   usage: turn.usage, errorCode: errorCode)
        }
    }

    private func persist(_ turn: LiveTurn, _ write: () throws -> Void) {
        do {
            try write()
        } catch {
            turn.persistError = "Couldn't save the reply: \(error.localizedDescription)"
        }
    }

    private func finalize(_ phase: LiveTurn.Phase) {
        guard let turn = liveTurn, turn.isRunning else { return }
        turn.finish(phase, at: clock())
        switch phase {
        case .complete:
            finalizePersist(turn, status: "complete", error: nil)
        case let .failed(error):
            finalizePersist(turn, status: "error", error: error)
        case .interrupted, .running:
            finalizePersist(turn, status: "partial", error: nil)
        }
        liveTurn = nil
        onTurnFinished?(turn)
    }

    /// The terminal write: message state + `:::artifact` versions (CHAT-05
    /// storage side) commit together in one transaction (`ChatTurnStore.
    /// finalizeTurn`) — a crash or write failure can never leave one without
    /// the other. An errored turn writes no artifacts (the store skips the
    /// parse for `status == "error"`).
    private func finalizePersist(_ turn: LiveTurn, status: String, error: ChatSessionError?) {
        lastFlush = clock()
        do {
            try store.finalizeTurn(conversationID: conversationID, messageID: turn.messageID, text: turn.fullText,
                                   status: status, usage: turn.usage, error: error)
        } catch {
            turn.persistError = "Couldn't finalize the reply: \(error.localizedDescription)"
        }
    }
}
