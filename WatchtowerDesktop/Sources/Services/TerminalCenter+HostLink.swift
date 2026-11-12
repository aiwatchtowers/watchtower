import Foundation
import WatchtowerCore

/// A lost session host connection is not an exit (#1086): the owner's
/// Reconnect, and a relaunch that attaches to a run the host still holds.
extension TerminalCenter {
    /// What `adoptLiveHostRun` found.
    enum LiveHostRun: Equatable {
        /// The host holds no live run of the row (or there is no host to
        /// ask): a launch may go ahead.
        case none
        /// The row shows a run: a live one the host held, adopted now, or
        /// the one it already showed. Nothing is to be launched.
        case shown
        /// The host could not say: nothing is launched, so no second agent
        /// can start beside one still running.
        case unknown(String)
    }

    /// Before a relaunch of `session` (Restart, an open of a stopped
    /// session; #1086): a live run of the row the session host still holds
    /// in this workspace — one the pane lost and read as ended — is adopted
    /// (the newest), so no `--resume` starts a second agent on one
    /// transcript. A host that cannot be reached at all is no answer to
    /// wait for: the launch reaches the same host and says why in its pane.
    func adoptLiveHostRun(_ session: TerminalSession) async -> LiveHostRun {
        if states[session.id] == .running { return .shown }
        guard let host = await connectedSessionHost() else { return .none }
        let listed: [SessionHostSessionInfo]
        do {
            listed = try await host.list()
        } catch {
            NSLog("TerminalCenter: could not list the session host's runs for session %lld: %@",
                  session.id, String(describing: error))
            return .unknown(error.localizedDescription)
        }
        if states[session.id] == .running { return .shown }
        let scope = sessionHostScope
        guard let newest = listed
            .filter({ $0.row == session.id && !$0.exited && ($0.scope.isEmpty || $0.scope == scope) })
            .max(by: { $0.startedAtMs < $1.startedAtMs }) else { return .none }
        adopt(session, info: newest)
        return .shown
    }

    /// The owner's Reconnect on a disconnected session (#1086).
    func reconnect(sessionID: Int64) {
        (process(for: sessionID) as? HostedTerminalSession)?.reconnectNow()
    }
}
