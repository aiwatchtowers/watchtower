import Foundation
import GRDB
import os
import WatchtowerCore

/// Keeps each workbench's session-report summaries for the
/// `terminal_session` slice's `report_*` fields (mobile POC spec §4.5):
/// `watchtower workbench session-report --workbench N --summary --json`, as
/// `SessionReportCenter` runs it. Every 60 s per workbench with a live
/// session, and on a session state change of a workbench, coalesced (at most
/// once per `minSpacing`). A failed, undecodable or hung run keeps the last
/// values. The loop sleeps until a state change wakes it or a deferred
/// request is due, at most `Timing.idle` (board #842).
///
/// Off the main actor, like `WorkbenchGitRefresher`: plain tasks, a lock,
/// and a synchronous `summary(workbenchID:sessionID:)` for the slice. Each
/// run is bounded by `Timing.timeout`. It never touches the relay processor.
final class SessionReportSummaryRunner: HubCompanion, Sendable {
    typealias Fetch = @Sendable (Int64) async throws -> [SessionReportSummary]

    struct Timing: Equatable, Sendable {
        /// The regular run of a workbench with a live session.
        let every: Duration
        /// The least time between two runs of one workbench, for a state
        /// change request (the coalescing).
        let minSpacing: Duration
        /// The bound on one CLI run.
        let timeout: Duration
        /// The longest wait between two passes with no state change (board
        /// #842); a change wakes the loop, at most once per
        /// `HubRunnerWake.standardMinimumGap`.
        let idle: Duration

        static let standard = Self(every: .seconds(60), minSpacing: .seconds(5), timeout: .seconds(20), idle: .seconds(15))
    }

    private struct Entry {
        var summaries: [Int64: SessionReportSummary]?
        var lastAttempt: ContinuousClock.Instant?
        var requested = false
    }

    private struct State {
        var entries: [Int64: Entry] = [:]
        /// When the earliest request the last pass deferred (inside
        /// `minSpacing`) is due; nil when it deferred none.
        var nextRequestDue: ContinuousClock.Instant?
    }

    /// What `takeDue` changed for one workbench, so a pass that did not
    /// finish its run can put it back.
    private struct Taken {
        let id: Int64
        let previous: Entry?
        let stamp: ContinuousClock.Instant
    }

    private let fetch: Fetch
    private let workbenches: @Sendable () async throws -> Workbenches
    private let timing: Timing
    private let clock: @Sendable () -> ContinuousClock.Instant
    /// Whether a pass runs at all (the hub's linked-phone gate).
    private let isActive: @Sendable () -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wake: HubRunnerWake
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: Constants.bundleID, category: "SessionReportSummaryRunner")

    /// The workbenches a pass works over.
    struct Workbenches: Sendable {
        /// With a live agent session: the 60 s cadence.
        let live: [Int64]
        /// Published (`WorkbenchSlice.publishedWorkbenchRefs`): a requested
        /// workbench runs while listed here; one that leaves it is forgotten
        /// with its summaries.
        let published: Set<Int64>
    }

    /// - Parameter wake: the loop's wait between passes.
    init(
        fetch: @escaping Fetch,
        workbenches: @escaping @Sendable () async throws -> Workbenches,
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        isActive: @escaping @Sendable () -> Bool = { true },
        wake: HubRunnerWake = HubRunnerWake()
    ) {
        self.fetch = fetch
        self.workbenches = workbenches
        self.timing = timing
        self.clock = clock
        self.isActive = isActive
        self.wake = wake
    }

    /// The hub's runner: the CLI through `runner`, over the published
    /// workbenches and those with a live session per `liveness`; no pass
    /// runs while `isActive` is false.
    static func live(
        _ runner: any CLIRunnerProtocol,
        dbPool: DatabasePool,
        liveness: SessionLivenessBox,
        isActive: @escaping @Sendable () -> Bool = { true }
    ) -> SessionReportSummaryRunner {
        SessionReportSummaryRunner(fetch: cliFetch(runner), workbenches: { [liveness] in
            let live = liveness.current.liveIDs
            return try await dbPool.read { db in
                Workbenches(
                    live: try TerminalSessionSlice.liveWorkbenchIDs(db, liveIDs: live),
                    published: Set(try WorkbenchSlice.publishedWorkbenchRefs(db).map(\.id))
                )
            }
        }, isActive: isActive)
    }

    /// The CLI run and its decode, as `SessionReportCenter.runSummary`.
    static func cliFetch(_ runner: any CLIRunnerProtocol) -> Fetch {
        { workbenchID in
            let args = ["workbench", "session-report", "--workbench", String(workbenchID), "--summary", "--json"]
            let data = try await runner.run(args: args)
            return try JSONDecoder().decode([SessionReportSummary].self, from: data)
        }
    }

    /// The last good summary of a session; nil before its workbench's first
    /// good run, or when the summary does not name it.
    func summary(workbenchID: Int64, sessionID: Int64) -> SessionReportSummary? {
        state.withLock { $0.entries[workbenchID]?.summaries?[sessionID] }
    }

    /// A session of `workbenchID` changed state: wakes the loop, which runs
    /// it no sooner than `minSpacing` after its last run.
    /// A workbench that is not published when the next pass lists them is
    /// dropped with the request.
    func sessionStateChanged(workbenchID: Int64) {
        state.withLock { $0.entries[workbenchID, default: Entry()].requested = true }
        wake.signal()
    }

    /// One pass over the due workbenches, one after the other. A `stop()`
    /// during the pass ends it before its next run; the run in flight stores
    /// nothing, and every workbench the pass did not finish stays due.
    /// - Returns: the workbenches whose CLI run was started.
    @discardableResult
    func runDue() async -> Set<Int64> {
        let passGeneration = generation.withLock { $0 }
        let listed: Workbenches
        do {
            listed = try await workbenches()
        } catch {
            logger.error("session report summary: listing workbenches failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard isCurrent(passGeneration) else { return [] }
        var attempted: Set<Int64> = []
        var unfinished = takeDue(listed, now: clock())
        while let next = unfinished.first {
            guard !Task.isCancelled, isCurrent(passGeneration) else { break }
            attempted.insert(next.id)
            let completed = await run(next.id, passGeneration: passGeneration)
            guard completed else { break }
            unfinished.removeFirst()
        }
        restore(unfinished)
        return attempted
    }

    private func isCurrent(_ passGeneration: Int) -> Bool {
        generation.withLock { $0 == passGeneration }
    }

    /// Forgets workbenches no longer published, stamps the due ones as
    /// attempted now, and notes when the earliest deferred request is due.
    private func takeDue(_ listed: Workbenches, now: ContinuousClock.Instant) -> [Taken] {
        state.withLock { [timing] state in
            state.entries = state.entries.filter { listed.published.contains($0.key) }
            state.nextRequestDue = nil
            let liveSet = Set(listed.live).intersection(listed.published)
            let candidates = Array(Set(state.entries.keys).union(liveSet)).sorted()
            var due: [Taken] = []
            for id in candidates {
                let previous = state.entries[id]
                var entry = previous ?? Entry()
                let isDue: Bool = {
                    guard let last = entry.lastAttempt else { return liveSet.contains(id) || entry.requested }
                    let elapsed = now - last
                    return (liveSet.contains(id) && elapsed >= timing.every) || (entry.requested && elapsed >= timing.minSpacing)
                }()
                guard isDue else {
                    if entry.requested, let last = entry.lastAttempt {
                        state.nextRequestDue = min(state.nextRequestDue ?? last + timing.minSpacing, last + timing.minSpacing)
                    }
                    continue
                }
                entry.lastAttempt = now
                entry.requested = false
                state.entries[id] = entry
                due.append(Taken(id: id, previous: previous, stamp: now))
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

    /// Puts back the cadence state of workbenches the pass did not finish,
    /// unless a later pass stamped them since.
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
    /// counts as finished: it keeps the last values and waits its turn).
    private func run(_ id: Int64, passGeneration: Int) async -> Bool {
        let fetch = self.fetch
        let result = await MobileHubService.bounded(timing.timeout) { () -> Result<[SessionReportSummary], any Error> in
            do {
                return .success(try await fetch(id))
            } catch {
                return .failure(error)
            }
        }
        guard isCurrent(passGeneration) else { return false }
        switch result {
        case nil:
            logger.warning("session report summary for workbench \(id) timed out; keeping the last values")
        case .failure(let error)?:
            logger.warning("session report summary for workbench \(id) failed: \(error.localizedDescription, privacy: .public)")
        case .success(let rows)?:
            store(Dictionary(rows.map { ($0.sessionID, $0) }) { _, last in last }, for: id)
        }
        return true
    }

    private func store(_ summaries: [Int64: SessionReportSummary], for id: Int64) {
        state.withLock { state in
            // The workbench may have been forgotten while the run was out.
            guard state.entries[id] != nil else { return }
            state.entries[id]?.summaries = summaries
        }
    }

    // MARK: - HubCompanion

    func start() {
        generation.withLock { $0 += 1 }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.isActive()
                if active { await self.runDue() }
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
