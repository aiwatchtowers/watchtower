import Foundation
import WatchtowerKit
import WatchtowerSync

/// The session detail's actions menu (spec §6.5): Stop on a live session,
/// with the phone's stop in place until the Mac applies it, Finish on a
/// live session when this phone may type into sessions (PROJ-16), and
/// Interrupt (#517) only while the session shows Working with no permission
/// prompt pending (there the card offers Deny: an Esc never answers one).
struct SessionActionsModel: Equatable {
    /// The phone's stop (or interrupt) on its way, or the Mac's refusal of
    /// it.
    struct StopRow: Equatable, Identifiable {
        enum State: Equatable {
            case sending(String)
            case failed(String)
        }

        var id: String { pending.id }
        let state: State
        let pending: PendingAction

        var isSending: Bool {
            if case .sending = state { true } else { false }
        }

        /// "Stop" or "Interrupt".
        var title: String { pending.action.kind == .sessionInterrupt ? "Interrupt" : "Stop" }
    }

    let canStop: Bool
    let stopRows: [StopRow]
    let canInterrupt: Bool
    let interruptRows: [StopRow]
    /// Finish asks the session to wrap up: only where the phone's lines go
    /// (`SessionInputModel.showsFinish`).
    let showsFinish: Bool

    var hasActions: Bool { canStop || showsFinish || canInterrupt }

    init(
        session: TerminalSessionState,
        snapshot: WorkbenchReplicaSnapshot,
        inFlight: Set<String>,
        now: Date,
        showsFinish: Bool = false,
        grant: DeviceGrant? = nil,
        typingRequested: Bool = false
    ) {
        self.showsFinish = showsFinish
        let entity = SessionStarter.sessionRecordName(session.id)
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        let rows: (ActionKind, String, String) -> [StopRow] = { kind, sending, fallback in
            snapshot.pending
                .filter { $0.action.kind == kind && $0.entityRecordName == entity }
                .map { row in
                    switch row.state {
                    case .pending:
                        StopRow(state: .sending(online ? sending : BoardWriteText.waitingForMac), pending: row)
                    case .failed:
                        StopRow(state: .failed(SessionStartText.failure(row, fallback: fallback)), pending: row)
                    }
                }
        }
        stopRows = rows(.sessionStop, SessionStartText.stopping, SessionStartText.stopFailed)
        interruptRows = rows(.sessionInterrupt, BoardWriteText.sending, "Your Mac could not interrupt the session")
        let stopping = inFlight.contains(SessionStarter.stopKey(session.id)) || stopRows.contains(where: \.isSending)
        canStop = session.live && !stopping
        let interrupting = inFlight.contains(SessionInputSender.interruptKey(session.id)) || interruptRows.contains(where: \.isSending)
        // The hub interrupts Claude sessions only.
        canInterrupt = session.live && session.agent == .claudeCode && session.stateKind == .working
            && typingRequested && grant?.typingAllowed == true
            && snapshot.pendingPermission(for: session.id) == nil
            && !interrupting
    }
}
