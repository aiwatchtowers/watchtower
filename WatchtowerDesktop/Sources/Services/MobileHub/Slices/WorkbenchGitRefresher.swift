import Foundation
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
/// run keeps the last value.
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
        /// How often the loop looks for due workbenches.
        let wake: Duration

        static let standard = Self(every: .seconds(120), minSpacing: .seconds(30), timeout: .seconds(20), wake: .seconds(5))
    }

    private struct Entry {
        var snapshot: WorkbenchGitSnapshot?
        var lastAttempt: ContinuousClock.Instant?
        var requested = false
    }

    private let fetch: Fetch
    private let workbenchIDs: @Sendable () async throws -> [Int64]
    private let timing: Timing
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let entries = OSAllocatedUnfairLock<[Int64: Entry]>(initialState: [:])
    private let onChange = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: Constants.bundleID, category: "WorkbenchGitRefresher")

    /// - Parameters:
    ///   - workbenchIDs: the workbenches to keep a status for (the published
    ///     ones); a workbench that leaves the list is forgotten.
    init(
        fetch: @escaping Fetch,
        workbenchIDs: @escaping @Sendable () async throws -> [Int64],
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.fetch = fetch
        self.workbenchIDs = workbenchIDs
        self.timing = timing
        self.clock = clock
    }

    /// The last good status; nil before the first one.
    func status(for workbenchID: Int64) -> WorkbenchGitSnapshot? {
        entries.withLock { $0[workbenchID]?.snapshot }
    }

    /// Runs after a status changed (the hub nudges the `workbench` kind).
    func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange.withLock { $0 = handler }
    }

    /// A session of `workbenchID` changed state: refresh at the next wake,
    /// but no sooner than `minSpacing` after its last run.
    func sessionStateChanged(workbenchID: Int64) {
        entries.withLock { entries in
            guard entries[workbenchID] != nil else { return }
            entries[workbenchID]?.requested = true
        }
    }

    /// One pass: runs every due workbench, one after the other. A `stop()`
    /// during the pass ends it before its next run, and the run in flight
    /// stores nothing.
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
        for id in takeDue(ids: ids, now: clock()) {
            guard !Task.isCancelled, isCurrent(passGeneration) else { break }
            attempted.insert(id)
            await refresh(id, passGeneration: passGeneration)
        }
        return attempted
    }

    private func isCurrent(_ passGeneration: Int) -> Bool {
        generation.withLock { $0 == passGeneration }
    }

    /// Forgets workbenches that left `ids`, adds new ones, and stamps the
    /// due ones as attempted now.
    private func takeDue(ids: [Int64], now: ContinuousClock.Instant) -> [Int64] {
        entries.withLock { [timing] entries in
            let wanted = Set(ids)
            entries = entries.filter { wanted.contains($0.key) }
            var due: [Int64] = []
            for id in ids {
                var entry = entries[id] ?? Entry()
                let isDue: Bool = {
                    guard let last = entry.lastAttempt else { return true }
                    let elapsed = now - last
                    return elapsed >= timing.every || (entry.requested && elapsed >= timing.minSpacing)
                }()
                if isDue {
                    entry.lastAttempt = now
                    entry.requested = false
                    due.append(id)
                }
                entries[id] = entry
            }
            return due
        }
    }

    private func refresh(_ id: Int64, passGeneration: Int) async {
        let fetch = self.fetch
        let result = await MobileHubService.bounded(timing.timeout) { () -> Result<WorkbenchGitStatus, any Error> in
            do {
                return .success(try await fetch(id))
            } catch {
                return .failure(error)
            }
        }
        guard isCurrent(passGeneration) else { return }
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
    }

    private func store(_ snapshot: WorkbenchGitSnapshot, for id: Int64) {
        let changed = entries.withLock { entries -> Bool in
            // The workbench may have been forgotten while the run was out.
            guard entries[id] != nil, entries[id]?.snapshot != snapshot else { return false }
            entries[id]?.snapshot = snapshot
            return true
        }
        if changed { onChange.withLock { $0 }?() }
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
                await self.refreshDue()
                try? await Task.sleep(for: self.timing.wake)
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
