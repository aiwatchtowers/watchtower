import Foundation
import os
import WatchtowerCore

extension SessionReportRunner {
    /// One pass: resolves pending state changes into milestones, prunes the
    /// sidecar, then runs the due sessions one after the other (phone
    /// requests first). A `stop()` during the pass ends it before its next
    /// run; the run in flight stores nothing, and every session the pass did
    /// not finish stays due.
    /// - Returns: the sessions whose CLI run was started, in order.
    @discardableResult
    func runDue() async -> [Int64] {
        let passGeneration = generation.withLock { $0 }
        // Taken before the read: a change the fast lane reports while the
        // read is out stays pending for the next pass (the read may predate it).
        let changedAt = takeStatesChanged()
        let listed: [SessionReportSlice.Windowed]
        do {
            listed = try await window()
        } catch {
            logger.error("session report: listing the sessions failed: \(error.localizedDescription, privacy: .public)")
            restoreStatesChanged(changedAt)
            return []
        }
        guard isCurrent(passGeneration) else {
            restoreStatesChanged(changedAt)
            return []
        }
        if let changedAt { observeStates(listed, changedAt: changedAt) }
        prune(keeping: Set(listed.map(\.sessionID)))
        let stored: Set<Int64>
        do {
            stored = Set(try sidecar.sessionReports().keys)
        } catch {
            logger.error("session report: reading the stored reports failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        var attempted: [Int64] = []
        var unfinished = takeDue(listed, stored: stored, now: clock())
        while let next = unfinished.first {
            guard !Task.isCancelled, isCurrent(passGeneration) else { break }
            attempted.append(next.sessionID)
            guard await run(next, passGeneration: passGeneration) == .finished else { break }
            unfinished.removeFirst()
        }
        restore(unfinished)
        return attempted
    }

    private func isCurrent(_ passGeneration: Int) -> Bool {
        generation.withLock { $0 == passGeneration }
    }

    // MARK: - State milestones

    /// Stores a `state` milestone for each session whose resolved state text
    /// changed since its last stored one, and marks those sessions changed.
    /// `changedAt`: when the fast lane first reported the change.
    private func observeStates(_ listed: [SessionReportSlice.Windowed], changedAt: Date) {
        do {
            let latest = try sidecar.stateMilestones().compactMapValues(\.first)
            let cutoff = now().addingTimeInterval(-HubSyncState.milestoneLifetime)
            var transitions: [Int64] = []
            for session in listed {
                guard let text = SessionTimelineSlice.stateText(session.state) else { continue }
                let last = latest[session.sessionID]
                guard last?.text != text else { continue }
                let at: Date
                if let last {
                    at = max(changedAt, last.at)
                    transitions.append(session.sessionID)
                } else {
                    // First sighting: the state's own time.
                    at = session.stateAt ?? session.lastActiveAt
                    guard at >= cutoff else { continue }
                }
                try sidecar.addStateMilestone(.init(sessionID: session.sessionID, at: at, text: text))
            }
            state.withLock { [transitions] state in
                for id in transitions { state.entries[id, default: Entry()].stateChanged = true }
            }
        } catch {
            logger.error("session report: storing state milestones failed: \(error.localizedDescription, privacy: .public)")
            // Resolved again at the next pass.
            restoreStatesChanged(changedAt)
        }
    }

    /// Takes and clears the pending state change stamp.
    private func takeStatesChanged() -> Date? {
        state.withLock { state -> Date? in
            defer { state.statesChangedAt = nil }
            return state.statesChangedAt
        }
    }

    /// Puts a taken stamp back, keeping the earlier of it and one reported
    /// since.
    private func restoreStatesChanged(_ changedAt: Date?) {
        guard let changedAt else { return }
        state.withLock { state in
            state.statesChangedAt = min(state.statesChangedAt ?? changedAt, changedAt)
        }
    }

    /// Drops the stored reports of sessions that left the window and the
    /// milestones past 14 days or a session's newest 100.
    private func prune(keeping ids: Set<Int64>) {
        do {
            try sidecar.removeSessionReports(keeping: ids)
            try sidecar.pruneSessionMilestones(olderThan: now().addingTimeInterval(-HubSyncState.milestoneLifetime))
        } catch {
            logger.error("session report: pruning the sidecar failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Cadence

    /// Forgets sessions no longer in the window, and stamps the due ones as
    /// attempted now; phone requests first.
    private func takeDue(_ listed: [SessionReportSlice.Windowed], stored: Set<Int64>, now: ContinuousClock.Instant) -> [Taken] {
        state.withLock { [timing] state in
            let ids = Set(listed.map(\.sessionID))
            state.entries = state.entries.filter { ids.contains($0.key) }
            var due: [Taken] = []
            for session in listed {
                let id = session.sessionID
                let previous = state.entries[id]
                var entry = previous ?? Entry()
                let isDue: Bool = {
                    if entry.networkRequested { return true }
                    guard let last = entry.lastAttempt else {
                        return !stored.contains(id) || session.live || entry.stateChanged
                    }
                    let elapsed = now - last
                    return (session.live && elapsed >= timing.every) || (entry.stateChanged && elapsed >= timing.stateSpacing)
                }()
                guard isDue else { continue }
                let network = entry.networkRequested
                entry.lastAttempt = now
                entry.stateChanged = false
                entry.networkRequested = false
                state.entries[id] = entry
                due.append(Taken(sessionID: id, workbenchID: session.workbenchID, network: network, previous: previous, stamp: now))
            }
            return due.filter(\.network) + due.filter { !$0.network }
        }
    }

    /// Puts back the cadence state of runs the pass did not finish, unless a
    /// later pass stamped them since.
    private func restore(_ unfinished: [Taken]) {
        guard !unfinished.isEmpty else { return }
        state.withLock { state in
            for taken in unfinished {
                guard var entry = state.entries[taken.sessionID], entry.lastAttempt == taken.stamp else { continue }
                entry.lastAttempt = taken.previous?.lastAttempt
                entry.stateChanged = entry.stateChanged || taken.previous?.stateChanged == true
                entry.networkRequested = entry.networkRequested || taken.network
                state.entries[taken.sessionID] = entry
            }
        }
    }

    private enum RunOutcome {
        /// The pass's generation ended during the run: nothing stored.
        case cut
        /// The run ended (a failure keeps the stored report and counts as
        /// finished).
        case finished
    }

    private func run(_ taken: Taken, passGeneration: Int) async -> RunOutcome {
        let fetch = self.fetch
        let result = await MobileHubService.bounded(timing.timeout) { () -> Result<SessionReport, any Error> in
            do {
                return .success(try await fetch(taken.workbenchID, taken.sessionID, taken.network))
            } catch {
                return .failure(error)
            }
        }
        guard isCurrent(passGeneration) else { return .cut }
        let id = taken.sessionID
        switch result {
        case nil:
            logger.warning("session report for session \(id) timed out; keeping the stored one")
        case .failure(let error)?:
            logger.warning("session report for session \(id) failed: \(error.localizedDescription, privacy: .public)")
        case .success(let report)?:
            do {
                try sidecar.saveSessionReport(try SessionReportSlice.encode(report), sessionID: id, at: now())
            } catch {
                logger.error("storing the session report of \(id) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .finished
    }
}
