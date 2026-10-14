import Foundation
import WatchtowerKit
import WatchtowerSync

/// The session detail's actions menu (spec §6.5): Stop on a live session,
/// with the phone's stop in place until the Mac applies it, and Finish on a
/// live session when this phone may type into sessions (PROJ-16).
struct SessionActionsModel: Equatable {
    /// The phone's stop on its way, or the Mac's refusal of it.
    struct StopRow: Equatable, Identifiable {
        enum State: Equatable {
            case sending(String)
            case failed(String)
        }

        var id: String { pending.id }
        let state: State
        let pending: PendingAction
    }

    let canStop: Bool
    let stopRows: [StopRow]
    /// Finish asks the session to wrap up: only where the phone's lines go
    /// (`SessionInputModel.showsFinish`).
    let showsFinish: Bool

    var hasActions: Bool { canStop || showsFinish }

    init(
        session: TerminalSessionState,
        snapshot: WorkbenchReplicaSnapshot,
        inFlight: Set<String>,
        now: Date,
        showsFinish: Bool = false
    ) {
        self.showsFinish = showsFinish
        let entity = SessionStarter.sessionRecordName(session.id)
        let online = MacStatus(heartbeat: snapshot.heartbeat, now: now).isOnline
        stopRows = snapshot.pending
            .filter { $0.action.kind == .sessionStop && $0.entityRecordName == entity }
            .map { row in
                switch row.state {
                case .pending:
                    StopRow(state: .sending(online ? SessionStartText.stopping : BoardWriteText.waitingForMac), pending: row)
                case .failed:
                    StopRow(state: .failed(SessionStartText.failure(row, fallback: SessionStartText.stopFailed)), pending: row)
                }
            }
        let stopping = inFlight.contains(SessionStarter.stopKey(session.id))
            || stopRows.contains { if case .sending = $0.state { true } else { false } }
        canStop = session.live && !stopping
    }
}
