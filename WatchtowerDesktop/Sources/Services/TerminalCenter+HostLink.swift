import Foundation
import WatchtowerCore

/// A lost session host connection is not an exit (#1086): the owner's
/// Reconnect, a relaunch that attaches to a run the host still holds, and
/// the stop of a row's other live runs.
extension TerminalCenter {
    /// What `adoptLiveHostRun` found.
    enum LiveHostRun: Equatable {
        /// There is no session host client to ask, or the host holds no
        /// live run of the row: a launch may go ahead.
        case none
        /// The row shows a run: a live one the host held, adopted now, or
        /// the one it already showed. Nothing is to be launched.
        case shown
        /// The host could not be reached or could not say (the reason):
        /// nothing is launched, so no second agent can start beside one
        /// still running.
        case unknown(String)
    }

    /// Before a relaunch of `session` (Restart, an open of a stopped
    /// session; #1086): the newest live run of the row the session host
    /// still holds in this workspace — one the pane lost and read as ended —
    /// is adopted, so no `--resume` starts a second agent on one
    /// transcript; any other live run of the row goes to `extraHostRuns`.
    /// A host that does not answer (even one only slow under load) is no
    /// answer: `.unknown`. Only with no client at all may the launch go
    /// ahead (it then says why in its pane).
    func adoptLiveHostRun(_ session: TerminalSession) async -> LiveHostRun {
        if states[session.id] == .running { return .shown }
        switch await liveHostRuns(of: session.id) {
        case .noClient:
            return .none
        case let .unreachable(reason):
            return .unknown(reason)
        case let .listed(_, runs):
            if states[session.id] == .running { return .shown }
            guard let newest = runs.first else { return .none }
            adopt(session, info: newest)
            setExtraHostRuns(Array(runs.dropFirst()), row: session.id)
            return .shown
        }
    }

    /// Stops every live run the host holds for row `id` but the one the row
    /// shows running (the pane's Stop under "Another run…", a close, Start
    /// fresh; #1086), each by its pid as just listed — hang-up, kill after
    /// the grace — then forgets it; the row's other runs stay in
    /// `extraHostRuns` until those stops are done. Returns why it could not,
    /// with the row's other runs kept; nil when nothing live is left beside
    /// the shown run (or there is no session host client).
    func stopLiveHostRuns(of id: Int64) async -> String? {
        switch await liveHostRuns(of: id) {
        case .noClient:
            setExtraHostRuns([], row: id)
            return nil
        case let .unreachable(reason):
            NSLog("TerminalCenter: could not stop session %lld's other runs: %@", id, reason)
            return reason
        case let .listed(host, runs):
            // Tracked while they stop, so a quit meanwhile waits for them.
            if !runs.isEmpty { setExtraHostRuns(runs, row: id) }
            await withTaskGroup(of: Void.self) { group in
                for info in runs {
                    group.addTask { @MainActor in await self.stopStray(info, host: host) }
                }
            }
            // Only now: until the kills are done the runs stay tracked, so
            // a quit meanwhile (`closeAll`) still waits for them.
            setExtraHostRuns([], row: id)
            return nil
        }
    }

    /// The owner's Reconnect on a disconnected session (#1086).
    func reconnect(sessionID: Int64) {
        (process(for: sessionID) as? HostedTerminalSession)?.reconnectNow()
    }

    private enum HostRuns {
        case noClient
        case unreachable(String)
        /// This workspace's live runs of the row, newest first, without the
        /// one the row shows running.
        case listed(SessionHostClient, [SessionHostSessionInfo])
    }

    private func liveHostRuns(of id: Int64) async -> HostRuns {
        guard hasSessionHostClient else { return .noClient }
        guard let host = await connectedSessionHost() else { return .unreachable(HostedTerminalSession.hostNotRunningReason) }
        let listed: [SessionHostSessionInfo]
        do {
            listed = try await host.list()
        } catch {
            NSLog("TerminalCenter: could not list the session host's runs for session %lld: %@",
                  id, String(describing: error))
            return .unreachable(error.localizedDescription)
        }
        let scope = sessionHostScope
        let shown = states[id] == .running ? (process(for: id) as? HostedTerminalSession)?.key : nil
        let runs = listed
            .filter { $0.row == id && !$0.exited && ($0.scope.isEmpty || $0.scope == scope) }
            .filter { SessionHostAttachRequest(row: $0.row, run: $0.run) != shown }
            .sorted { $0.startedAtMs > $1.startedAtMs }
        return .listed(host, runs)
    }
}
