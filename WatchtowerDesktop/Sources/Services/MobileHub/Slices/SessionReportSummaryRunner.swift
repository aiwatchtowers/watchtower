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
/// values.
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
        /// How often the loop looks for due workbenches.
        let wake: Duration

        static let standard = Self(every: .seconds(60), minSpacing: .seconds(5), timeout: .seconds(20), wake: .seconds(5))
    }

    private struct Entry {
        var summaries: [Int64: SessionReportSummary]?
        var lastAttempt: ContinuousClock.Instant?
        var requested = false
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
    private let entries = OSAllocatedUnfairLock<[Int64: Entry]>(initialState: [:])
    private let onChange = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: Constants.bundleID, category: "SessionReportSummaryRunner")

    /// The workbenches a pass works over.
    struct Workbenches: Sendable {
        /// With a live `claude` session: the 60 s cadence.
        let live: [Int64]
        /// Published (`WorkbenchSlice.publishedWorkbenches`): a requested
        /// workbench runs while listed here; one that leaves it is forgotten
        /// with its summaries.
        let published: Set<Int64>
    }

    init(
        fetch: @escaping Fetch,
        workbenches: @escaping @Sendable () async throws -> Workbenches,
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.fetch = fetch
        self.workbenches = workbenches
        self.timing = timing
        self.clock = clock
    }

    /// The hub's runner: the CLI through `runner`, over the published
    /// workbenches and those with a live session per `liveness`.
    static func live(_ runner: any CLIRunnerProtocol, dbPool: DatabasePool, liveness: SessionLivenessBox) -> SessionReportSummaryRunner {
        SessionReportSummaryRunner(fetch: cliFetch(runner)) { [liveness] in
            let live = liveness.current.liveIDs
            return try await dbPool.read { db in
                Workbenches(
                    live: try TerminalSessionSlice.liveWorkbenchIDs(db, liveIDs: live),
                    published: Set(try WorkbenchSlice.publishedWorkbenches(db).map(\.id))
                )
            }
        }
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
        entries.withLock { $0[workbenchID]?.summaries?[sessionID] }
    }

    /// Runs after a workbench's summaries changed (the hub nudges the
    /// `terminal_session` kind).
    func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange.withLock { $0 = handler }
    }

    /// A session of `workbenchID` changed state: run it at the next wake,
    /// but no sooner than `minSpacing` after its last run.
    /// A workbench that is not published when the next pass lists them is
    /// dropped with the request.
    func sessionStateChanged(workbenchID: Int64) {
        entries.withLock { $0[workbenchID, default: Entry()].requested = true }
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

    /// Forgets workbenches no longer published, and stamps the due ones as
    /// attempted now.
    private func takeDue(_ listed: Workbenches, now: ContinuousClock.Instant) -> [Taken] {
        entries.withLock { [timing] entries in
            entries = entries.filter { listed.published.contains($0.key) }
            let liveSet = Set(listed.live).intersection(listed.published)
            let candidates = Array(Set(entries.keys).union(liveSet)).sorted()
            var due: [Taken] = []
            for id in candidates {
                let previous = entries[id]
                var entry = previous ?? Entry()
                let isDue: Bool = {
                    guard let last = entry.lastAttempt else { return liveSet.contains(id) || entry.requested }
                    let elapsed = now - last
                    return (liveSet.contains(id) && elapsed >= timing.every) || (entry.requested && elapsed >= timing.minSpacing)
                }()
                guard isDue else { continue }
                entry.lastAttempt = now
                entry.requested = false
                entries[id] = entry
                due.append(Taken(id: id, previous: previous, stamp: now))
            }
            return due
        }
    }

    /// Puts back the cadence state of workbenches the pass did not finish,
    /// unless a later pass stamped them since.
    private func restore(_ unfinished: [Taken]) {
        guard !unfinished.isEmpty else { return }
        entries.withLock { entries in
            for taken in unfinished {
                guard var entry = entries[taken.id], entry.lastAttempt == taken.stamp else { continue }
                entry.lastAttempt = taken.previous?.lastAttempt
                entry.requested = entry.requested || (taken.previous?.requested ?? false)
                entries[taken.id] = entry
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
        let changed = entries.withLock { entries -> Bool in
            // The workbench may have been forgotten while the run was out.
            guard entries[id] != nil, entries[id]?.summaries != summaries else { return false }
            entries[id]?.summaries = summaries
            return true
        }
        if changed { onChange.withLock { $0 }?() }
    }

    // MARK: - HubCompanion

    func start() {
        generation.withLock { $0 += 1 }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runDue()
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
