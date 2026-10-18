import Foundation
import Observation
import WatchtowerCore

/// One session's Workchat composer (#711, spec §4): the draft, the lines sent
/// from it and Stop. Lines go through `SessionLineDelivery` with key
/// `.workchat(id)` behind `SessionControl.lineCheck` — PROJ-16's gate, with
/// no device grant at the Mac. Held by `WorkbenchesViewModel` per session, so
/// the draft and the queued lines survive pane switches; nothing is stored.
@MainActor
@Observable
final class WorkchatModel {
    typealias Delivery = SessionLineDelivery.Delivery

    let sessionID: Int64
    var draft = ""
    /// The lines sent from here and not yet shown by the feed, oldest first.
    private(set) var outgoing: [WorkchatOutgoing] = []
    /// Why the last Stop could not be checked; the next Stop clears it.
    private(set) var stopError: String?

    @ObservationIgnored private let control: SessionControl
    @ObservationIgnored private let lineDelivery: SessionLineDelivery
    @ObservationIgnored private let now: () -> Date
    /// Feed entries that stood for a line already: one echo, one line.
    @ObservationIgnored private var claimedEntries: Set<String> = []

    init(sessionID: Int64, control: SessionControl, lineDelivery: SessionLineDelivery, now: @escaping () -> Date = Date.init) {
        self.sessionID = sessionID
        self.control = control
        self.lineDelivery = lineDelivery
        self.now = now
    }

    /// Sends the trimmed draft; an empty or whitespace-only one is not sent.
    /// The field clears at once; a line that cannot go comes back to it.
    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        let id = UUID()
        outgoing.append(WorkchatOutgoing(id: id, text: text, sentAt: now(), state: .sending))
        let delivery = await lineDelivery.deliverLine(
            text, key: .workchat(id), sessionID: sessionID,
            gate: { [weak control] in Self.gate(control?.lineCheck($0)) },
            onHeldEvent: { [weak self] event in
                guard case let .tried(delivery) = event else { return }
                self?.settle(id, delivery)
            }
        )
        settle(id, delivery)
    }

    /// Drops a queued line before it goes. A line already on its way (its
    /// retry under way) is not in the queue and stays.
    func cancel(_ id: UUID) {
        guard outgoing.first(where: { $0.id == id })?.state == .queued else { return }
        let dropped = lineDelivery.dropHeld(sessionID: sessionID) { $0 == .workchat(id) }
        guard !dropped.isEmpty else { return }
        outgoing.removeAll { $0.id == id }
    }

    /// The feed changed: a line whose owner entry it now shows leaves. A
    /// submitted line past `echoWindow` without one stays as a plain bubble;
    /// a typed or copied line waits for the owner's Return however long.
    func reconcile(with entries: [SessionFeedEntry]) {
        let owners = entries.filter { $0.kind == "owner" && !claimedEntries.contains($0.id) }
        guard !owners.isEmpty else { return }
        let current = now()
        var kept: [WorkchatOutgoing] = []
        var claimed = Set<String>()
        for line in outgoing {
            guard Self.awaitsEcho(line, now: current),
                  let echo = owners.first(where: { !claimed.contains($0.id) && WorkchatOutgoing.matches($0, line: line) })
            else {
                kept.append(line)
                continue
            }
            claimed.insert(echo.id)
        }
        guard !claimed.isEmpty else { return }
        claimedEntries.formUnion(claimed)
        outgoing = kept
    }

    /// One Esc into the working agent, refused while a permission prompt is
    /// pending (the permission card covers it).
    func stop() async -> SessionControl.InterruptResult {
        stopError = nil
        do {
            return try await control.interrupt(sessionID)
        } catch {
            stopError = "Could not check for a permission prompt: \(error.localizedDescription)"
            return .notWorking
        }
    }

    private static func awaitsEcho(_ line: WorkchatOutgoing, now: Date) -> Bool {
        switch line.state {
        case .sent:
            guard let delivered = line.deliveredAt else { return true }
            return now.timeIntervalSince(delivered) <= WorkchatOutgoing.echoWindow
        case .typed, .copied: return true
        case .sending, .queued, .notSent: return false
        }
    }

    nonisolated private static func gate(_ check: SessionControl.LineCheck?) -> SessionLineDelivery.GateAnswer {
        switch check {
        case .go: .go
        case .hold: .hold
        case .sessionGone, nil: .drop
        }
    }

    /// A delivery's outcome on the line's bubble; a line that cannot go
    /// any more puts its text back in an empty field.
    private func settle(_ id: UUID, _ delivery: Delivery) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        let state: WorkchatOutgoing.State = switch delivery {
        case .submitted: .sent
        case .held, .queued: .queued
        case .typed: .typed
        case .copied: .copied
        case .noSession: .notSent
        }
        outgoing[index].state = state
        switch state {
        case .sent, .typed, .copied: outgoing[index].deliveredAt = now()
        case .notSent: if draft.isEmpty { draft = outgoing[index].text }
        case .sending, .queued: break
        }
    }
}
