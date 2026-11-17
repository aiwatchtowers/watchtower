import Foundation
import Observation

/// Folds a session's v2 events into the live turn the chat draws. Owned by
/// the session client (app-lifetime, on the pool), never by a view model —
/// so a turn keeps streaming when the owner navigates away.
///
/// It writes nothing (mobile Inbox spec §8): `ai session --persist` saves
/// the turn's rows — its start, its text, steps and end, and its lease. A
/// turn begins at the session's `started` (its rows exist), ends exactly
/// once — `turn_done`, a turn-scoped `error`, or `finishRunningAsPartial`
/// (stop watchdog, process death, eviction, quit) — and stays `liveTurn`
/// (no longer running, its full text still shown) until the session's
/// `turn_saved` says its last write landed (`isFinishing`). Then
/// `onTurnFinished` fires, so what a reload reads is the turn's final state.
@MainActor
@Observable
package final class ChatTurnDriver {
    package private(set) var liveTurn: LiveTurn?
    package private(set) var sessionID: String?
    package private(set) var actualProvider: String?
    package private(set) var actualModel: String?
    package private(set) var routing: ChatRoutingMetadata?
    /// The actual provider's capability row from its session_ready (nil
    /// until one names its provider).
    package private(set) var actualCapabilities: ProviderCapabilities?
    package private(set) var lastSessionError: ChatSessionError?
    /// The turn ended and the session's last write for it is under way:
    /// the turn can no longer be stopped, and no next turn starts until it
    /// landed.
    package private(set) var isFinishing = false
    /// A turn is running or finishing.
    package var isBusy: Bool { liveTurn?.isRunning == true || isFinishing }

    @ObservationIgnored package let conversationID: Int64
    @ObservationIgnored package var onTurnFinished: ((LiveTurn) -> Void)?
    /// A step started waiting on this `agent_actions` row. The session
    /// subprocess wrote the row, which no app observation sees, so the
    /// action feeds re-read now — the card the step points at must exist
    /// while the turn is blocked on it, not at the turn's end.
    @ObservationIgnored package var onActionAwaited: ((Int64) -> Void)?
    @ObservationIgnored private let clock: () -> Date

    package init(conversationID: Int64, clock: @escaping () -> Date = Date.init) {
        self.conversationID = conversationID
        self.clock = clock
    }

    /// Starts tracking the turn whose rows the session just wrote.
    @discardableResult
    package func begin(messageID: Int64, turnID: String) -> LiveTurn {
        let turn = LiveTurn(messageID: messageID, turnID: turnID, startedAt: clock())
        liveTurn = turn
        isFinishing = false
        return turn
    }

    package func apply(_ event: ChatEvent) {
        switch event {
        case let .sessionReady(sid, provider, model, routing, capabilities):
            record(sid)
            self.routing = routing
            if !provider.isEmpty {
                actualProvider = provider
                actualModel = model
            }
            // A session_ready that names its provider replaces the row (nil
            // when it carries none: the catalog's row is read instead); the
            // routing placeholder names none and keeps it.
            if capabilities != nil || !provider.isEmpty { actualCapabilities = capabilities }
        case .turnStart, .started, .refused:
            break
        case let .textDelta(turnID, text):
            running(turnID)?.appendDelta(text, now: clock())
        case let .toolStart(start):
            _ = running(start.turnID)?.startStep(start, at: clock())
        case let .toolEnd(end):
            running(end.turnID)?.finishStep(end, at: clock())
        case let .toolWait(wait):
            stepWaiting(wait)
        case let .usage(usage):
            running(usage.turnID)?.setUsage(usage)
        case let .turnDone(turnID, status, sid):
            record(sid)
            guard running(turnID) != nil else { return }
            end(status == .complete ? .complete : .interrupted)
        case let .error(error):
            handle(error)
        case let .turnSaved(turnID):
            saved(turnID)
        case .saveError:
            break  // the client keeps it for the thread (`ChatSessionClient.saveError`)
        case .exited:
            finishRunningAsPartial()
        }
    }

    /// A session-level failure observed outside the event stream (the
    /// process died without a terminal event) — kept for the UI.
    package func noteSessionError(_ error: ChatSessionError) {
        lastSessionError = error
    }

    /// Stop watchdog, process death, eviction, app quit: whatever streamed
    /// stays on screen as `partial`, and nothing more comes for the turn —
    /// it ends now (the session wrote what it could, or `chat.recover`
    /// marks it).
    package func finishRunningAsPartial() {
        guard let turn = liveTurn else { return }
        if turn.isRunning { turn.finish(.interrupted, at: clock()) }
        settle(turn)
    }

    // MARK: - Private

    private func running(_ turnID: String) -> LiveTurn? {
        guard let turn = liveTurn, turn.isRunning, turn.turnID == turnID else { return nil }
        return turn
    }

    private func record(_ sid: String?) {
        guard let sid, !sid.isEmpty else { return }
        sessionID = sid
    }

    /// Waiting is live only; a wait whose `tool_start` never arrived first
    /// starts a nameless step, so the call stays a visible step (CHAT-02).
    private func stepWaiting(_ wait: ChatToolWait) {
        guard let turn = running(wait.turnID) else { return }
        if !turn.steps.contains(where: { $0.id == wait.id }) {
            _ = turn.startStep(ChatToolStart(turnID: wait.turnID, id: wait.id, name: "", argsJSON: "{}"), at: clock())
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
        end(.failed(error))
    }

    /// The turn's end event: its final write is the session's; the turn
    /// stays on screen until `turn_saved`.
    private func end(_ phase: LiveTurn.Phase) {
        guard let turn = liveTurn, turn.isRunning else { return }
        turn.finish(phase, at: clock())
        isFinishing = true
    }

    /// The session let go of the turn: written, or lost (its conversation
    /// deleted, its lease taken) — a turn still running then ends here.
    private func saved(_ turnID: String) {
        guard let turn = liveTurn, turn.turnID == turnID else { return }
        if turn.isRunning { turn.finish(.interrupted, at: clock()) }
        settle(turn)
    }

    private func settle(_ turn: LiveTurn) {
        if liveTurn === turn { liveTurn = nil }
        isFinishing = false
        onTurnFinished?(turn)
    }
}
