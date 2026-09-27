import Foundation

/// Pure pool decisions (the `WarmEnginePolicy` precedent): no clock reads,
/// no I/O. `ChatSessionPool` gathers snapshots and applies the actions.
/// CHAT-03: at most `maxLive` live session processes; an idle one dies
/// within `idleTTL` + one `pollInterval`. A running turn is never cut to
/// make room — a fourth conversation waits for a slot instead.
package enum ChatSessionPolicy {
    package static let maxLive = 3
    package static let idleTTL: TimeInterval = 10 * 60
    package static let pollInterval: Duration = .seconds(30)

    package struct SessionSnapshot: Equatable, Sendable {
        package let conversationID: Int64
        package let lastActivity: Date
        package let busy: Bool
        package let alive: Bool

        package init(conversationID: Int64, lastActivity: Date, busy: Bool, alive: Bool) {
            self.conversationID = conversationID
            self.lastActivity = lastActivity
            self.busy = busy
            self.alive = alive
        }
    }

    package enum PoolAction: Equatable, Sendable {
        case evict(Int64)
        case spawn(Int64)
    }

    /// `sessions` are the launched sessions; `retiring` counts processes
    /// already told to close that have not exited yet — they still occupy a
    /// slot. A busy session (a turn in flight) is NEVER evicted: when no idle
    /// session can make room, no `.spawn` is returned and the wanted session
    /// stays queued until a turn finishes. `.evict` + `.spawn` in one result
    /// is a plan: the pool launches only after the evicted processes exit, so
    /// the bound holds for processes, not just for bookkeeping.
    package static func decide(
        sessions: [SessionSnapshot], now: Date, wanted: Int64?, retiring: Int = 0
    ) -> [PoolAction] {
        var actions: [PoolAction] = sessions.filter { !$0.alive }.map { .evict($0.conversationID) }
        var live = sessions.filter(\.alive)
        let expired = live.filter {
            !$0.busy && $0.conversationID != wanted && now.timeIntervalSince($0.lastActivity) >= idleTTL
        }
        actions += expired.map { .evict($0.conversationID) }
        let expiredIDs = Set(expired.map(\.conversationID))
        live.removeAll { expiredIDs.contains($0.conversationID) }

        guard let wanted, !live.contains(where: { $0.conversationID == wanted }) else { return actions }
        // Idle sessions only, least recently used first.
        var candidates = live.filter { !$0.busy }.sorted { $0.lastActivity < $1.lastActivity }
        var occupied = live.count + retiring
        while occupied >= maxLive, !candidates.isEmpty {
            let victim = candidates.removeFirst()
            actions.append(.evict(victim.conversationID))
            occupied -= 1
        }
        if occupied < maxLive { actions.append(.spawn(wanted)) }
        return actions
    }
}
