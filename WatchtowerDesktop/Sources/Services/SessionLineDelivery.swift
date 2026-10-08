import Foundation

/// The one path a line takes into a Claude Code session's prompt for the
/// app — an owner ask's answer (PROJ-12), and the phone's session input
/// after it (mobile POC spec §6.6) — so every line follows PROJ-12's rules:
/// held while the session waits on a permission prompt or its state cannot
/// be read right before the paste, pasted as one line, and submitted only
/// where the session's hooks vouch for this run and no draft is in the
/// prompt. Owned by `AppState` (through `WorkbenchesViewModel`).
///
/// One queue per session: while a line is going to a session (paste,
/// pause, Return) another one for it waits, so two lines never share a
/// prompt. Held lines live in memory only, and go on the next read of the
/// session states that succeeds (`deliverHeld`, wired to
/// `SessionAgentStateCenter.onChange`/`onRead`) — never on a timer.
@MainActor
final class SessionLineDelivery {
    /// Where a line went (PROJ-12, board #379).
    enum Delivery: Equatable {
        /// Pasted into the session and submitted with Return (or by the
        /// owner's own Return during the pause).
        case submitted
        /// Pasted without Return — the session's hooks reported nothing this
        /// run, its prompt held text not submitted (the owner's, or another
        /// line's — a hand-off's too, even one still in its pause), a state
        /// read failed, or a permission prompt
        /// appeared during the pause: the owner presses it.
        case typed
        /// Bracketed paste was off: on the clipboard, nothing typed.
        case copied
        /// The session waits on a permission prompt, or its state could not
        /// be read: nothing typed yet; the line goes on a later read
        /// (`deliverHeld`).
        case held
        /// Another line is going to the session right now: nothing typed
        /// yet; the line goes right after it.
        case queued
        /// No session running (or a new run started since): the session's
        /// next brief has it.
        case noSession
    }

    /// Whose line it is: an owner ask's answer, or another line (the
    /// phone's input, by its action id).
    enum LineKey: Hashable {
        case ask(Int64)
        case input(String)
    }

    /// What became of a held line when the held lines were tried again.
    enum HeldEvent: Equatable {
        /// Its session still waits on a permission prompt: not tried.
        case awaitingApproval
        /// Tried: where it went (`.held`/`.queued`: still held).
        case tried(Delivery)
    }

    /// Whether a session's agent waits on a permission prompt (its
    /// `SessionAgentStatus` is `needsApproval`): a line is held, never
    /// typed into the prompt.
    var needsApproval: (_ sessionID: Int64) -> Bool = { _ in false }
    /// Whether the session's hooks reported during its current run — a
    /// state, or the mark of a run the agent has not turned to yet
    /// (`SessionAgentStatus.hooksReported`, board #396): only then may a
    /// line's Return follow — without hooks the app cannot tell a
    /// permission prompt is on screen.
    var hasHookState: (_ sessionID: Int64) -> Bool = { _ in false }
    /// A fresh read of the session states, before a line goes and again
    /// after the paste's pause (the poll may be up to 1 s stale); returns
    /// whether the read succeeded — a Return needs both reads.
    var refreshStates: () async -> Bool = { false }

    private let terminalCenter: TerminalCenter?
    /// Each session's held and queued lines, oldest first.
    private var queues: [Int64: [HeldLine]] = [:]
    /// Sessions a line is going to right now (paste, pause, Return).
    private var delivering: Set<Int64> = []
    private var heldCount = 0

    init(terminalCenter: TerminalCenter?) {
        self.terminalCenter = terminalCenter
    }

    /// Sends `line` to the session now, or holds it (`.held`/`.queued`):
    /// a held line goes later, and `onHeldEvent` hears each try. It is
    /// called only for a held line, never for the result returned here.
    func deliverLine(
        _ line: String, key: LineKey, sessionID: Int64,
        onHeldEvent: @escaping (HeldEvent) -> Void
    ) async -> Delivery {
        let delivery = await deliver(line, key: key, sessionID: sessionID)
        if delivery == .held || delivery == .queued {
            heldCount += 1
            queueHeldLine(HeldLine(order: heldCount, key: key, sessionID: sessionID, line: line,
                             run: terminalCenter?.runs[sessionID], onEvent: onHeldEvent))
        }
        return delivery
    }

    /// The session states changed or were read again
    /// (`SessionAgentStateCenter.onChange`/`onRead`): each held line whose
    /// session no longer waits on a permission prompt goes now — answers by
    /// ask id (as before the extraction), then other lines oldest first.
    /// One whose session stopped or started again meanwhile goes nowhere —
    /// the session's brief has it.
    func deliverHeld() async {
        let held = queues.values.joined().sorted {
            ($0.key.askID ?? .max, $0.order) < ($1.key.askID ?? .max, $1.order)
        }
        for line in held {
            await retryHeldLine(line)
        }
    }

    /// The keys of a session's held and queued lines.
    func heldKeys(sessionID: Int64) -> Set<LineKey> {
        Set((queues[sessionID] ?? []).map(\.key))
    }

    /// Drops a session's held lines `include` picks: they are not typed at
    /// all. Returns their keys; no event is sent for them.
    @discardableResult
    func dropHeld(sessionID: Int64, where include: (LineKey) -> Bool) -> [LineKey] {
        let dropped = (queues[sessionID] ?? []).filter { include($0.key) }
        queues[sessionID]?.removeAll { include($0.key) }
        if queues[sessionID]?.isEmpty == true { queues[sessionID] = nil }
        return dropped.map(\.key)
    }

    private func retryHeldLine(_ held: HeldLine) async {
        guard isQueued(held), !delivering.contains(held.sessionID) else { return }
        if needsApproval(held.sessionID) {
            held.onEvent(.awaitingApproval)
            return
        }
        // Taken before any wait, so an overlapping call never sends it twice.
        removeHeldLine(held)
        let sameRun = terminalCenter?.runs[held.sessionID] == held.run
        let delivery = sameRun ? await deliver(held.line, key: held.key, sessionID: held.sessionID) : .noSession
        if delivery == .held || delivery == .queued { queueHeldLine(held) }
        held.onEvent(.tried(delivery))
    }

    /// The line goes to a running session: queued while another line is
    /// going to it, held while it waits on a permission prompt (a Return
    /// could confirm the prompt's default) or while its state cannot be read
    /// right before the paste, otherwise pasted, and submitted after
    /// `TerminalCenter.answerSubmitDelay` only when the state read after the
    /// pause succeeded too, the session's hooks
    /// reported this run (a state, or the run's mark) and still show no
    /// permission prompt after
    /// the pause, and its prompt held no text not submitted; else the paste
    /// waits for the owner's Return. While the agent works, Claude Code
    /// queues the submitted line for its next turn. Without bracketed paste
    /// the line is copied, never typed.
    private func deliver(_ line: String, key: LineKey, sessionID: Int64) async -> Delivery {
        guard let center = terminalCenter, center.liveIDs.contains(sessionID),
              let run = center.runs[sessionID] else { return .noSession }
        guard !delivering.contains(sessionID) else { return .queued }
        delivering.insert(sessionID)
        defer {
            delivering.remove(sessionID)
            // The lines held behind this one go next.
            if queues[sessionID]?.isEmpty == false {
                Task { [weak self] in await self?.deliverHeld() }
            }
        }
        // A failed read leaves the last good state, which may miss a
        // permission prompt shown since: hold, and try again on the next
        // read that succeeds (`SessionAgentStateCenter.onRead`).
        let fresh = await refreshStates()
        // A relaunch during the read is a new run: the line was meant for
        // the one before, whose brief has it (board #387).
        guard center.liveIDs.contains(sessionID), center.runs[sessionID] == run else { return .noSession }
        if !fresh || needsApproval(sessionID) {
            NSLog("%@: session %lld: %@ held — %@", key.logSource, sessionID, key.logNoun,
                  fresh ? "permission prompt (needsApproval)" : "state read failed")
            return .held
        }
        let result = await center.submitPrompt(line, sessionID: sessionID, keepingLineBreaks: false,
                                               delay: TerminalCenter.answerSubmitDelay,
                                               refresh: refreshStates) { [weak self] in
            self?.mayReturn(key: key, sessionID: sessionID) ?? false
        }
        switch result {
        case .submitted: return .submitted
        case .pasted: return .typed
        case .copied: return .copied
        case .noSession: return .noSession
        }
    }

    /// Whether the line's Return may follow after the pause; the condition
    /// that withholds it is logged.
    private func mayReturn(key: LineKey, sessionID: Int64) -> Bool {
        let withheld: String? = if !hasHookState(sessionID) {
            "no hook state this run"
        } else if needsApproval(sessionID) {
            "permission prompt (needsApproval)"
        } else {
            nil
        }
        if let withheld { NSLog("%@: session %lld: Return withheld — %@", key.logSource, sessionID, withheld) }
        return withheld == nil
    }

    private func isQueued(_ held: HeldLine) -> Bool {
        queues[held.sessionID]?.contains { $0.order == held.order } == true
    }

    /// Back in its session's queue at its own place: a line held again
    /// keeps its turn.
    private func queueHeldLine(_ held: HeldLine) {
        var queue = queues[held.sessionID] ?? []
        let index = queue.firstIndex { $0.order > held.order } ?? queue.count
        queue.insert(held, at: index)
        queues[held.sessionID] = queue
    }

    private func removeHeldLine(_ held: HeldLine) {
        queues[held.sessionID]?.removeAll { $0.order == held.order }
        if queues[held.sessionID]?.isEmpty == true { queues[held.sessionID] = nil }
    }
}

extension SessionLineDelivery.LineKey {
    /// The ask an answer's line is for; nil for another line.
    var askID: Int64? {
        if case let .ask(id) = self { id } else { nil }
    }

    /// The app log's source: an answer's lines keep `OwnerAsks` (PROJ-12).
    fileprivate var logSource: String {
        switch self {
        case .ask: "OwnerAsks"
        case .input: "SessionInput"
        }
    }

    fileprivate var logNoun: String {
        switch self {
        case .ask: "answer"
        case .input: "line"
        }
    }
}

/// A line waiting for its session to leave a permission prompt, or for the
/// line before it.
private struct HeldLine {
    /// When it was first held: the queue's order.
    let order: Int
    let key: SessionLineDelivery.LineKey
    let sessionID: Int64
    let line: String
    /// The session's process run (`TerminalCenter.runs`) when the line was
    /// held; it never goes into a later run (that run's brief has it).
    let run: Int?
    let onEvent: (SessionLineDelivery.HeldEvent) -> Void
}
