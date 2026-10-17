import Foundation
import os
import WatchtowerCore

/// What the projection needs of the Mac's terminals and state center: the
/// sessions whose process runs and when each run started
/// (`TerminalCenter.liveIDs` and `startedAt`), and the sessions whose
/// background agent count the center shows as over after two failed
/// staleness probes (`SessionAgentStateCenter.displayOver`, #411) — all
/// main-actor state. The fast lane copies it here, so the slice can resolve
/// states inside the publisher's off-main DB read the way the Mac does.
/// `settled` is false until the launch's reattach of the session host's
/// runs is done (`TerminalCenter.hostRunsSettled`): before it, a session
/// that survived the restart is missing from `liveIDs`, so nothing may be
/// written over a session for not being live.
struct SessionLiveness: Equatable, Sendable {
    var liveIDs: Set<Int64> = []
    var startedAt: [Int64: Date] = [:]
    var displayOver: [Int64: ShownOverCount] = [:]
    var settled = false

    /// The sessions of `rows` shown over: only where the row still holds
    /// the count the center judged (the same run and report stamp), so a
    /// newer background report read here is never published as Stopped.
    func shownOver(_ rows: [SessionAgentStateRow]) -> Set<Int64> {
        var over: Set<Int64> = []
        for row in rows where displayOver[row.id] == ShownOverCount(run: startedAt[row.id], reportedAt: row.agentBackgroundAt) {
            over.insert(row.id)
        }
        return over
    }
}

/// A background agent count the state center shows as over: the session's
/// run and the count's `agent_background_at` it was judged for.
struct ShownOverCount: Equatable, Sendable {
    let run: Date?
    let reportedAt: String?

    /// `over`'s sessions with the run and report stamp of `rows`.
    static func of(_ over: Set<Int64>, rows: [SessionAgentStateRow], startedAt: [Int64: Date]) -> [Int64: Self] {
        var counts: [Int64: Self] = [:]
        for row in rows where over.contains(row.id) {
            counts[row.id] = Self(run: startedAt[row.id], reportedAt: row.agentBackgroundAt)
        }
        return counts
    }
}

/// The lock-guarded `SessionLiveness` the fast lane writes and the slice
/// reads.
final class SessionLivenessBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: SessionLiveness())

    var current: SessionLiveness { state.withLock { $0 } }

    /// Stores `next`; whether it differed from the stored value.
    @discardableResult
    func update(_ next: SessionLiveness) -> Bool {
        state.withLock { current in
            guard current != next else { return false }
            current = next
            return true
        }
    }
}

/// The sessions waiting in the Desktop's Undo batch (board #480, PROJ-17),
/// copied from `WorkbenchesViewModel.pendingDeletes` on every change, so
/// the slice can leave them out inside the publisher's off-main DB read.
final class HiddenSessionIDsBox: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: Set<Int64>())

    var current: Set<Int64> { state.withLock { $0 } }

    func store(_ ids: Set<Int64>) {
        state.withLock { $0 = ids }
    }
}
