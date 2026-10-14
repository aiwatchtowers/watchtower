import CloudKit
import Foundation
import os

// MARK: - Push fetch (the phone's silent pushes, board #724)

extension CloudKitTransport {
    /// Phone role, after a silent push that arrived at `since`: the light
    /// fetch. CKSyncEngine (`automaticallySync`, left on for both roles: it
    /// also sends) fetches on the same push by itself, so this waits for
    /// that own run instead of fetching twice: a run that began at or after
    /// `since` covers the push (a running one is awaited). Only when none
    /// begins within `grace` of `since` does it fetch through the engine
    /// itself, without `pull()`'s forced zone poll (that stays in the
    /// timed and pull-to-refresh paths, which keep its guarantee). Joins a
    /// running push fetch or pull. No-op while the engine is unavailable,
    /// unlinked or throttled; errors are handled as in `pull()`.
    ///
    /// `pollOnFallback`: the fallback fetch also runs the forced zone poll.
    /// The engine fetches only the zones a delivered push told it about, so
    /// without the poll the fallback may send no request at all; the
    /// foreground asks for it (the owner is looking), the background keeps
    /// the light fetch.
    public func fetchForPush(since: Date, grace: TimeInterval, pollOnFallback: Bool = false) async throws {
        if let pushFetchTask {
            pushFetchJoins += 1
            return try await pushFetchTask.value
        }
        if let pullTask {
            pullJoins += 1
            return try await pullTask.value
        }
        guard let engine, !isUnlinked else { return }
        if let throttledUntil, now() < throttledUntil { return }
        let task = Task {
            defer {
                self.pushFetchTask = nil
                self.pushFetchFetching = false
            }
            try await self.performPushFetch(engine: engine, since: since, grace: grace, poll: pollOnFallback)
        }
        pushFetchTask = task
        try await task.value
    }

    /// How long a push fetch waits for a running own engine run to end
    /// before fetching itself: a run that never reports its end must not
    /// stall the push (and the caller's completion) for good.
    static func engineRunEndWait(grace: TimeInterval) -> TimeInterval {
        max(grace, 30)
    }

    private func performPushFetch(
        engine: any SyncEngineDriving, since: Date, grace: TimeInterval, poll: Bool
    ) async throws {
        if await engineRunCovers(since: since, grace: grace, engine: engine) {
            pushFetchesCoveredByEngine += 1
            return
        }
        // A pull that took the push over is its fetch.
        if let pullTask {
            pullJoins += 1
            return try await pullTask.value
        }
        guard self.engine === engine, !isUnlinked, !isStopped else { return }
        if let throttledUntil, now() < throttledUntil { return }
        pushFetchFetching = true
        try await performPull(engine: engine, poll: poll)
    }

    /// Whether an own engine fetch run that began at or after `since` has
    /// run (awaiting it if it is running, up to `engineRunEndWait`),
    /// waiting up to `since + grace` for one to begin. False once a wait
    /// runs out, a `pull()` takes the push over, or the engine is stopped
    /// or replaced.
    private func engineRunCovers(since: Date, grace: TimeInterval, engine: any SyncEngineDriving) async -> Bool {
        while self.engine === engine, !isStopped {
            if engineRunInFlight {
                let startedAt = engineRunStartedAt
                guard await waitForEngineRun(end: true, timeout: Self.engineRunEndWait(grace: grace)) else { return false }
                if let startedAt, startedAt >= since { return true }
                continue
            }
            if let startedAt = engineRunStartedAt, startedAt >= since { return true }
            let remaining = since.addingTimeInterval(grace).timeIntervalSince(now())
            guard remaining > 0 else { return false }
            guard await waitForEngineRun(end: false, timeout: remaining) else { return false }
        }
        return false
    }

    /// True when an own run begins (`end` false) or the running one ends
    /// (`end` true) within `timeout`. The timer stops once the wait ends.
    private func waitForEngineRun(end: Bool, timeout: TimeInterval) async -> Bool {
        let id = UUID()
        let sleep = sleep
        // Actor-isolated: the timer's expiry runs after this job suspends
        // below, so the waiter is registered before it can expire.
        let timer = Task {
            await sleep(timeout)
            self.expireEngineRunWaiter(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            if end {
                engineRunEndWaiters[id] = continuation
            } else {
                engineRunStartWaiters[id] = continuation
            }
        }
    }

    private func expireEngineRunWaiter(_ id: UUID) {
        (engineRunStartWaiters.removeValue(forKey: id) ?? engineRunEndWaiters.removeValue(forKey: id))?
            .resume(returning: false)
    }

    /// A `pull()` serves the waiting push fetch: it stops waiting on the
    /// engine (the run state stays as it is).
    func abandonEngineRunWaits() {
        let starts = engineRunStartWaiters
        let ends = engineRunEndWaiters
        engineRunStartWaiters = [:]
        engineRunEndWaiters = [:]
        starts.values.forEach { $0.resume(returning: false) }
        ends.values.forEach { $0.resume(returning: false) }
    }

    /// `willFetchChanges`. A manual fetch's own event (a pull, a push's
    /// fallback, an expired token's re-fetch) is not a run of the engine's
    /// (it is counted as `.engineFetch` where it starts).
    func engineWillFetch() {
        guard !manualFetchInFlight, !refetchFetchInFlight else { return }
        energy?.record(.engineFetchRun)
        engineRunInFlight = true
        engineRunStartedAt = now()
        let waiters = engineRunStartWaiters
        engineRunStartWaiters = [:]
        waiters.values.forEach { $0.resume(returning: true) }
    }

    /// `didFetchChanges`: the own run's fetched changes are buffered (the
    /// engine delivers its events in order).
    func engineDidFetch() {
        guard engineRunInFlight else { return }
        engineRunInFlight = false
        let waiters = engineRunEndWaiters
        engineRunEndWaiters = [:]
        waiters.values.forEach { $0.resume(returning: true) }
        engineFetchedHandler?()
    }

    /// The engine went (stop, account reset): nobody waits for its runs.
    func releaseEngineRunWaiters() {
        engineRunInFlight = false
        engineRunStartedAt = nil
        abandonEngineRunWaits()
    }
}
