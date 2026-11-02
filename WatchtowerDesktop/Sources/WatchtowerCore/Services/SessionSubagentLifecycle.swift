import Foundation

/// A nested agent may have no marker in the root feed. Its own fresh turn
/// and background-child state, rather than its originally pushed marker,
/// decide whether its live line and child polling continue.
package enum SessionSubagentLifecycle {
    package static func status(
        parentStatus: String,
        snapshot: SessionFeedLive?,
        error: String?,
        now: Date
    ) -> String {
        // Completion is durable evidence, not a heartbeat. An old pushed
        // running marker or failed refresh cannot revive this interval.
        if let snapshot, !snapshot.turnActive, snapshot.agentsState == "known", snapshot.agentsMore == 0,
           snapshot.agents.allSatisfy({ $0.ref.status == "finished" }) { return "finished" }
        guard error == nil, let snapshot, let observed = snapshot.observedAt,
              now.timeIntervalSince(observed) < WorkchatLivePresentation.staleAfter else { return parentStatus }
        if snapshot.turnActive { return "running" }
        if snapshot.agents.contains(where: { $0.ref.status == "running" }) { return "running" }
        if snapshot.agentsState != "known" || snapshot.agentsMore > 0
            || snapshot.agents.contains(where: { $0.ref.status == "unknown" }) { return "unknown" }
        return "finished"
    }
}

/// Identity/foreground/retry changes restart the pane's single observer.
/// Lifecycle updates are consumed inside that loop, never by self-cancelling it.
package struct SessionSubagentFollowKey: Hashable {
    package let follow: AnyHashable
    package let retry: UUID
    package let parentToolUseID: String?

    package init(follow: AnyHashable, retry: UUID, parentToolUseID: String?) {
        self.follow = follow
        self.retry = retry
        self.parentToolUseID = parentToolUseID
    }
}

/// The open pane's observation state. Completed history stays paused while
/// its immediate parent's actual snapshots supply evidence of another run.
package struct SessionSubagentObservation {
    package private(set) var finished = false
    private var own: SessionFeedLive?
    private var completedAt: Date?
    private var parentStatus: String?
    private var parentStartedAt: Date?

    package mutating func receiveOwn(
        snapshot: SessionFeedLive?, entries: [SessionFeedEntry], error: String?, now: Date
    ) -> String {
        if let snapshot { own = snapshot }
        let status = SessionSubagentLifecycle.status(parentStatus: "unknown", snapshot: own, error: error, now: now)
        finished = status == "finished"
        if finished { completedAt = entries.compactMap(\.at).max() ?? own?.observedAt }
        return status
    }

    package mutating func receiveParent(_ snapshot: SessionFeedLive?, childID: String, now: Date) -> Bool {
        guard let snapshot, let observed = snapshot.observedAt,
              now.timeIntervalSince(observed) < WorkchatLivePresentation.staleAfter,
              let child = snapshot.agents.first(where: { $0.id == childID }),
              child.ref.status == "running" || child.ref.status == "finished" else { return false }
        let newerInterval = child.startedAt.map { start in
            parentStartedAt.map { start > $0 } ?? (completedAt.map { start > $0 } ?? false)
        } ?? false
        let resumed = finished && child.ref.status == "running" && (parentStatus == "finished" || newerInterval)
        parentStatus = child.ref.status
        parentStartedAt = child.startedAt
        if resumed { finished = false; own = nil; completedAt = nil }
        return resumed
    }
}
