import Foundation
import GRDB
import os
import WatchtowerCore

/// What the `workbench` slice publishes of a folder's git status.
struct WorkbenchGitSnapshot: Equatable, Sendable {
    /// "" when HEAD is detached.
    let branch: String
    let detached: Bool
    let changes: Int
}

/// Keeps each published workbench's git status for the `workbench` slice
/// (mobile POC spec §4.2): `watchtower workbench git status --workbench N
/// --json` (`WorkbenchCLI.gitStatus`, PROJ-10's git — the hub never runs
/// git itself), every 120 s per workbench and on a state change of one of its
/// sessions, at most once per 30 s per workbench. A failed, refused or hung
/// run keeps the last value. The loop sleeps until a session change wakes it
/// or a deferred request is due, at most `Timing.idle` (board #842).
///
/// Off the main actor: the loop and the runs are plain tasks, and the slice
/// reads the cache synchronously under a lock inside its DB read. Each run is
/// bounded by `Timing.timeout`, so a hung CLI never stalls the loop.
final class WorkbenchGitRefresher: HubCompanion, Sendable {
    typealias Fetch = @Sendable (Int64) async throws -> WorkbenchGitStatus

    struct Timing: Equatable, Sendable {
        /// The regular refresh of one workbench.
        let every: Duration
        /// The least time between two runs for one workbench, for a
        /// session-change request.
        let minSpacing: Duration
        /// The bound on one CLI run.
        let timeout: Duration
        /// The longest wait between two passes with no session change
        /// (board #842); a change wakes the loop at once.
        let idle: Duration

        static let standard = Self(every: .seconds(120), minSpacing: .seconds(30), timeout: .seconds(20), idle: .seconds(15))
    }

    private struct Entry {
        var snapshot: WorkbenchGitSnapshot?
        var lastAttempt: ContinuousClock.Instant?
        var requested = false
    }

    private struct State {
        var entries: [Int64: Entry] = [:]
        /// When the earliest request the last pass deferred (inside
        /// `minSpacing`) is due; nil when it deferred none.
        var nextRequestDue: ContinuousClock.Instant?
    }

    private let fetch: Fetch
    private let workbenchIDs: @Sendable () async throws -> [Int64]
    private let timing: Timing
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// Whether a pass runs at all (the hub's linked-phone gate): with no
    /// phone nothing reads the status, so no CLI runs.
    private let isActive: @Sendable () -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wake: HubRunnerWake
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: Constants.bundleID, category: "WorkbenchGitRefresher")

    /// - Parameters:
    ///   - workbenchIDs: the workbenches to keep a status for (the published
    ///     ones); a workbench that leaves the list is forgotten.
    ///   - isActive: false skips the loop's passes (nothing is listed or run).
    ///   - wake: the loop's wait between passes.
    init(
        fetch: @escaping Fetch,
        workbenchIDs: @escaping @Sendable () async throws -> [Int64],
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        isActive: @escaping @Sendable () -> Bool = { true },
        wake: HubRunnerWake = HubRunnerWake()
    ) {
        self.fetch = fetch
        self.workbenchIDs = workbenchIDs
        self.timing = timing
        self.clock = clock
        self.isActive = isActive
        self.wake = wake
    }

    /// The hub's refresher: the CLI's `gitStatus` over the published
    /// workbenches (the light listing); no pass runs while `isActive` is
    /// false.
    static func live(cli: WorkbenchCLI, dbPool: DatabasePool, isActive: @escaping @Sendable () -> Bool) -> WorkbenchGitRefresher {
        WorkbenchGitRefresher(
            fetch: { try await cli.gitStatus(projectID: $0) },
            workbenchIDs: { try await dbPool.read { try WorkbenchSlice.publishedWorkbenchRefs($0).map(\.id) } },
            isActive: isActive
        )
    }

    /// The last good status; nil before the first one.
    func status(for workbenchID: Int64) -> WorkbenchGitSnapshot? {
        state.withLock { $0.entries[workbenchID]?.snapshot }
    }

    /// A session of `workbenchID` changed state: wakes the loop, which
    /// refreshes it no sooner than `minSpacing` after its last run (a
    /// workbench not listed yet runs as new on that pass).
    func sessionStateChanged(workbenchID: Int64) {
        state.withLock { state in
            guard state.entries[workbenchID] != nil else { return }
            state.entries[workbenchID]?.requested = true
        }
        wake.signal()
    }

    /// One pass: runs every due workbench, one after the other. A `stop()`
    /// during the pass ends it before its next run, the run in flight
    /// stores nothing, and every workbench the pass did not finish stays due.
    /// - Returns: the workbenches whose CLI run was started.
    @discardableResult
    func refreshDue() async -> Set<Int64> {
        let passGeneration = generation.withLock { $0 }
        let ids: [Int64]
        do {
            ids = try await workbenchIDs()
        } catch {
            logger.error("git status: listing workbenches failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard isCurrent(passGeneration) else { return [] }
        var attempted: Set<Int64> = []
        var unfinished = takeDue(ids: ids, now: clock())
        while let next = unfinished.first {
            guard !Task.isCancelled, isCurrent(passGeneration) else { break }
            attempted.insert(next.id)
            guard await refresh(next.id, passGeneration: passGeneration) else { break }
            unfinished.removeFirst()
        }
        restore(unfinished)
        return attempted
    }

    private func isCurrent(_ passGeneration: Int) -> Bool {
        generation.withLock { $0 == passGeneration }
    }

    /// What `takeDue` changed for one workbench, so a pass that did not
    /// finish its run can put it back.
    private struct Taken {
        let id: Int64
        let previous: Entry?
        let stamp: ContinuousClock.Instant
    }

    /// Forgets workbenches that left `ids`, adds new ones, stamps the due
    /// ones as attempted now, and notes when the earliest deferred request
    /// is due.
    private func takeDue(ids: [Int64], now: ContinuousClock.Instant) -> [Taken] {
        state.withLock { [timing] state in
            let wanted = Set(ids)
            state.entries = state.entries.filter { wanted.contains($0.key) }
            state.nextRequestDue = nil
            var due: [Taken] = []
            for id in ids {
                let previous = state.entries[id]
                var entry = previous ?? Entry()
                let isDue: Bool = {
                    guard let last = entry.lastAttempt else { return true }
                    let elapsed = now - last
                    return elapsed >= timing.every || (entry.requested && elapsed >= timing.minSpacing)
                }()
                if isDue {
                    entry.lastAttempt = now
                    entry.requested = false
                    due.append(Taken(id: id, previous: previous, stamp: now))
                } else if entry.requested, let last = entry.lastAttempt {
                    state.nextRequestDue = min(state.nextRequestDue ?? last + timing.minSpacing, last + timing.minSpacing)
                }
                state.entries[id] = entry
            }
            return due
        }
    }

    /// The wait before the next pass: until the earliest request the last
    /// pass deferred, else `idle`. Taken once, so a pass that did not get
    /// to `takeDue` (a failed listing) leaves the loop at `idle`.
    private func takeNextWait() -> Duration {
        let due = state.withLock { state -> ContinuousClock.Instant? in
            defer { state.nextRequestDue = nil }
            return state.nextRequestDue
        }
        return HubRunnerWake.duration(until: due, now: clock(), idle: timing.idle)
    }

    /// Puts back the cadence state of workbenches the pass did not finish
    /// (a stop cut it), unless a later pass stamped them since: a restart
    /// runs them at once and keeps their session-change requests.
    private func restore(_ unfinished: [Taken]) {
        guard !unfinished.isEmpty else { return }
        state.withLock { state in
            for taken in unfinished {
                guard var entry = state.entries[taken.id], entry.lastAttempt == taken.stamp else { continue }
                entry.lastAttempt = taken.previous?.lastAttempt
                entry.requested = entry.requested || (taken.previous?.requested ?? false)
                state.entries[taken.id] = entry
            }
        }
    }

    /// Whether the run finished under the pass's generation (a failure
    /// counts as finished: it keeps the last value and waits its turn).
    private func refresh(_ id: Int64, passGeneration: Int) async -> Bool {
        let fetch = self.fetch
        let result = await MobileHubService.bounded(timing.timeout) { () -> Result<WorkbenchGitStatus, any Error> in
            do {
                return .success(try await fetch(id))
            } catch {
                return .failure(error)
            }
        }
        guard isCurrent(passGeneration) else { return false }
        switch result {
        case nil:
            logger.warning("git status for workbench \(id) timed out; keeping the last value")
        case .failure(let error)?:
            logger.warning("git status for workbench \(id) failed: \(error.localizedDescription, privacy: .public)")
        case .success(let status)? where !status.statusOK:
            logger.warning("git status for workbench \(id) could not be read: \(status.statusError, privacy: .public)")
        case .success(let status)?:
            store(Self.snapshot(status), for: id)
        }
        return true
    }

    private func store(_ snapshot: WorkbenchGitSnapshot, for id: Int64) {
        state.withLock { state in
            // The workbench may have been forgotten while the run was out.
            guard state.entries[id] != nil else { return }
            state.entries[id]?.snapshot = snapshot
        }
    }

    static func snapshot(_ status: WorkbenchGitStatus) -> WorkbenchGitSnapshot {
        WorkbenchGitSnapshot(branch: status.detached ? "" : status.branch, detached: status.detached, changes: status.changes)
    }

    // MARK: - HubCompanion

    func start() {
        generation.withLock { $0 += 1 }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.isActive()
                if active { await self.refreshDue() }
                await self.wake.wait(upTo: active ? self.takeNextWait() : self.timing.idle)
            }
        }
        loopTask.withLock { current in
            current?.cancel()
            current = task
        }
    }

    func stop() {
        generation.withLock { $0 += 1 }
        loopTask.withLock { current in
            current?.cancel()
            current = nil
        }
    }
}
