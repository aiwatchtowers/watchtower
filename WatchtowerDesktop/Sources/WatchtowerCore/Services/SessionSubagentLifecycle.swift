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
    package private(set) var awaitingResume = false
    package private(set) var parentTransition: String?
    package var shouldReadOwn: Bool { !finished || awaitingResume }
    private var resumeEvidence: ResumeEvidence?
    private var ownEntryAt: Date?
    private var ownEntryIDs: Set<String> = []
    private var own: SessionFeedLive?
    private var completedAt: Date?
    private var parentStatus: String?
    private var parentStartedAt: Date?
    private var parentTerminal = false
    private var ownAdvancedBeyondParent = false

    package mutating func receiveOwn(
        snapshot: SessionFeedLive?, entries: [SessionFeedEntry], error: String?, now: Date
    ) -> String {
        var acknowledgedResume = false
        if awaitingResume {
            guard error == nil, let snapshot, let observed = snapshot.observedAt,
                  now.timeIntervalSince(observed) < WorkchatLivePresentation.staleAfter else {
                return parentTerminal ? "finished" : "unknown"
            }
            guard resumeEvidence?.acknowledged(by: snapshot, entries: entries) == true else {
                return parentTerminal ? "finished" : "resuming"
            }
            awaitingResume = false; resumeEvidence = nil; acknowledgedResume = true
        }
        if parentTerminal {
            let advanced = !acknowledgedResume && error == nil && snapshot.map {
                ownEvidence.acknowledged(by: $0, entries: entries, requireIntervalChange: true)
            } == true
            if advanced {
                parentTerminal = false; ownAdvancedBeyondParent = true
            } else {
                if acknowledgedResume, let snapshot { saveOwn(snapshot, entries: entries) }
                finished = true
                return "finished"
            }
        }
        if let snapshot { saveOwn(snapshot, entries: entries) }
        let status = SessionSubagentLifecycle.status(parentStatus: "unknown", snapshot: own, error: error, now: now)
        finished = status == "finished"
        if finished { completedAt = own?.observedAt ?? entries.compactMap(\.at).max() }
        return status
    }

    package mutating func receiveParent(_ snapshot: SessionFeedLive?, childID: String, now: Date) -> Bool {
        parentTransition = nil
        guard let snapshot, let observed = snapshot.observedAt,
              now.timeIntervalSince(observed) < WorkchatLivePresentation.staleAfter,
              let child = snapshot.agents.first(where: { $0.id == childID }),
              child.ref.status == "running" || child.ref.status == "finished" else { return false }
        if let prior = parentStartedAt, let current = child.startedAt, current < prior { return false }
        let newerInterval = child.startedAt.map { start in
            parentStartedAt.map { start > $0 } ?? (completedAt.map { start > $0 } ?? false)
        } ?? false
        if child.ref.status == "finished" {
            // A terminal marker for the prior parent interval cannot close a
            // newer own turn already observed while the parent catches up.
            if ownAdvancedBeyondParent && !newerInterval && parentStatus == "finished" { return false }
            if !finished || !parentTerminal { parentTransition = "finished" }
            parentStatus = "finished"; parentStartedAt = child.startedAt
            parentTerminal = true; finished = true
            return false
        }
        let catchesUpToOwn = ownAdvancedBeyondParent && !(child.startedAt.map { $0 > (own?.observedAt ?? .distantFuture) } ?? false)
        let resumed = finished && !catchesUpToOwn && (parentStatus == "finished" || newerInterval)
        parentStatus = "running"; parentStartedAt = child.startedAt
        parentTerminal = false; ownAdvancedBeyondParent = false
        if resumed {
            resumeEvidence = own == nil ? (resumeEvidence ?? ownEvidence) : ownEvidence
            awaitingResume = true; finished = false; own = nil; completedAt = nil
            parentTransition = "resuming"
        }
        return resumed
    }

    private var ownEvidence: ResumeEvidence {
        ResumeEvidence(turnAt: own?.turnAt, conversation: own?.conversation ?? "", wasActive: own?.turnActive ?? false,
                       entryAt: ownEntryAt, entryIDs: ownEntryIDs)
    }
    private mutating func saveOwn(_ snapshot: SessionFeedLive, entries: [SessionFeedEntry]) {
        own = snapshot; ownEntryAt = entries.compactMap(\.at).max(); ownEntryIDs = Set(entries.map(\.id))
    }
    private struct ResumeEvidence {
        let turnAt: Date?
        let conversation: String
        let wasActive: Bool
        let entryAt: Date?
        let entryIDs: Set<String>

        func acknowledged(by snapshot: SessionFeedLive, entries: [SessionFeedEntry], requireIntervalChange: Bool = false) -> Bool {
            if !conversation.isEmpty, !snapshot.conversation.isEmpty, snapshot.conversation != conversation { return true }
            if let prior = turnAt, let current = snapshot.turnAt { return current > prior }
            if snapshot.turnActive && !wasActive && !requireIntervalChange { return true }
            if let current = snapshot.turnAt, let entryAt, current > entryAt { return true }
            guard let prior = entryAt, let current = entries.compactMap(\.at).max(), current > prior else { return false }
            return entries.contains { !entryIDs.contains($0.id) }
        }
    }
}
