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

/// The raw parent marker can restart a resumed direct child. Own completion
/// intentionally is not part of the key, so it does not cause a second poll.
package struct SessionSubagentFollowKey: Hashable {
    package let follow: AnyHashable
    package let retry: UUID
    package let parentStatus: String

    package init(follow: AnyHashable, retry: UUID, parentStatus: String) {
        self.follow = follow
        self.retry = retry
        self.parentStatus = parentStatus
    }
}
