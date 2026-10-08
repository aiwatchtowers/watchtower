import Foundation
import GRDB
import os
import WatchtowerCore

/// Runs `watchtower workbench session-report --workbench N --session S
/// --json` for the `session_report` slice (mobile POC spec §4.8), with the
/// argv `SessionReportCenter` runs, and records the hub-observed state
/// milestones of the `session_timeline` slice (§4.9). Per session of the
/// report window (`SessionReportSlice.window`):
/// - every 120 s while the session is live, with `--no-network`;
/// - on a resolved state-kind change, coalesced: no sooner than 5 s after
///   its last run, with `--no-network`;
/// - once when the session has no stored report yet (with `--no-network`);
/// - on the phone's `session_report_request`, without `--no-network` (gh
///   refreshes the PR states), at most once per 60 s per session.
///
/// State changes come from the fast lane's chain on
/// `SessionAgentStateCenter` (`sessionStatesChanged()`); there is no second
/// observation loop. The next pass resolves the window's states and stores
/// a `state` milestone for each session whose state text differs from its
/// last stored one (the first sighting is stamped with the state's own
/// time, a transition with the time the fast lane reported it).
///
/// Off the main actor, like `SessionReportSummaryRunner`: plain tasks and a
/// lock. Each run is bounded by `Timing.timeout` (the runner's process is
/// terminated on the cancel). A failed, undecodable or hung run keeps the
/// stored report. The capped payloads live in the sidecar, so a restart
/// publishes them again at once; a session that leaves the window loses its
/// stored report. It never touches the relay processor.
final class SessionReportRunner: HubCompanion, Sendable {
    typealias Fetch = @Sendable (_ workbenchID: Int64, _ sessionID: Int64, _ network: Bool) async throws -> SessionReport
    typealias Window = @Sendable () async throws -> [SessionReportSlice.Windowed]

    struct Timing: Equatable, Sendable {
        /// The regular run of a live session.
        let every: Duration
        /// The least time between a session's last run and a state change's.
        let stateSpacing: Duration
        /// The least time between two accepted phone requests of a session.
        let requestSpacing: Duration
        /// The bound on one CLI run.
        let timeout: Duration
        /// How often the loop looks for due sessions.
        let wake: Duration

        static let standard = Self(
            every: .seconds(120), stateSpacing: .seconds(5), requestSpacing: .seconds(60), timeout: .seconds(30), wake: .seconds(5)
        )
    }

    private struct Entry {
        var lastAttempt: ContinuousClock.Instant?
        var stateChanged = false
        var networkRequested = false
        var lastRequest: ContinuousClock.Instant?
    }

    private struct State {
        var entries: [Int64: Entry] = [:]
        /// When the fast lane first reported a state change the runner has
        /// not resolved yet; nil when there is none.
        var statesChangedAt: Date?
    }

    /// One due run, and what `takeDue` changed, so a pass that did not
    /// finish it can put it back.
    private struct Taken {
        let sessionID: Int64
        let workbenchID: Int64
        let network: Bool
        let previous: Entry?
        let stamp: ContinuousClock.Instant
    }

    private let fetch: Fetch
    private let window: Window
    private let sidecar: HubSyncState
    private let timing: Timing
    private let clock: @Sendable () -> ContinuousClock.Instant
    private let now: @Sendable () -> Date
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onChange = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let logger = Logger(subsystem: Constants.bundleID, category: "SessionReportRunner")

    /// - Parameter window: the report window (`SessionReportSlice.window`).
    init(
        fetch: @escaping Fetch,
        sidecar: HubSyncState,
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        now: @escaping @Sendable () -> Date = { Date() },
        window: @escaping Window
    ) {
        self.fetch = fetch
        self.window = window
        self.sidecar = sidecar
        self.timing = timing
        self.clock = clock
        self.now = now
    }

    /// `SessionReportCenter`'s argv, plus `--no-network` for every run the
    /// phone did not ask for.
    static func arguments(workbenchID: Int64, sessionID: Int64, network: Bool) -> [String] {
        let args = ["workbench", "session-report", "--workbench", String(workbenchID), "--session", String(sessionID), "--json"]
        return network ? args : args + ["--no-network"]
    }

    /// The hub's runner: the CLI through `runner`, over the report window
    /// of `sessions`.
    static func live(
        _ runner: any CLIRunnerProtocol, dbPool: DatabasePool, sessions: TerminalSessionSlice, sidecar: HubSyncState
    ) -> SessionReportRunner {
        SessionReportRunner(fetch: cliFetch(runner), sidecar: sidecar) {
            try await dbPool.read { try SessionReportSlice.window($0, sessions: sessions, now: Date()) }
        }
    }

    /// The CLI run and its decode, as `SessionReportCenter.runReport`.
    static func cliFetch(_ runner: any CLIRunnerProtocol) -> Fetch {
        { workbenchID, sessionID, network in
            let data = try await runner.run(args: arguments(workbenchID: workbenchID, sessionID: sessionID, network: network))
            return try JSONDecoder().decode(SessionReport.self, from: data)
        }
    }

    /// Runs after a stored report or milestone changed (the hub nudges
    /// `session_report` and `session_timeline`).
    func setOnChange(_ handler: (@Sendable () -> Void)?) {
        onChange.withLock { $0 = handler }
    }

    /// The fast lane saw a session state change: the next pass resolves the
    /// window's states.
    func sessionStatesChanged() {
        let stamp = now()
        state.withLock { $0.statesChangedAt = $0.statesChangedAt ?? stamp }
    }

    /// The phone's `session_report_request`: a run with the network at the
    /// next pass. False when the session's last accepted request is less
    /// than `requestSpacing` old (nothing more runs).
    @discardableResult
    func requestReport(sessionID: Int64) -> Bool {
        let stamp = clock()
        return state.withLock { [timing] state in
            var entry = state.entries[sessionID] ?? Entry()
            if let last = entry.lastRequest, stamp - last < timing.requestSpacing { return false }
            entry.lastRequest = stamp
            entry.networkRequested = true
            state.entries[sessionID] = entry
            return true
        }
    }

    /// One pass: resolves pending state changes into milestones, prunes the
    /// sidecar, then runs the due sessions one after the other (phone
    /// requests first). A `stop()` during the pass ends it before its next
    /// run; the run in flight stores nothing, and every session the pass did
    /// not finish stays due.
    /// - Returns: the sessions whose CLI run was started, in order.
    @discardableResult
    func runDue() async -> [Int64] {
        let passGeneration = generation.withLock { $0 }
        let listed: [SessionReportSlice.Windowed]
        do {
            listed = try await window()
        } catch {
            logger.error("session report: listing the sessions failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard isCurrent(passGeneration) else { return [] }
        var changed = observeStates(listed)
        changed = prune(keeping: Set(listed.map(\.sessionID))) || changed
        let stored: Set<Int64>
        do {
            stored = Set(try sidecar.sessionReports().keys)
        } catch {
            logger.error("session report: reading the stored reports failed: \(error.localizedDescription, privacy: .public)")
            if changed { notify() }
            return []
        }
        var attempted: [Int64] = []
        var unfinished = takeDue(listed, stored: stored, now: clock())
        while let next = unfinished.first {
            guard !Task.isCancelled, isCurrent(passGeneration) else { break }
            attempted.append(next.sessionID)
            guard case let .finished(stored) = await run(next, passGeneration: passGeneration) else { break }
            changed = stored || changed
            unfinished.removeFirst()
        }
        restore(unfinished)
        if changed { notify() }
        return attempted
    }

    private func isCurrent(_ passGeneration: Int) -> Bool {
        generation.withLock { $0 == passGeneration }
    }

    private func notify() {
        onChange.withLock { $0 }?()
    }

    // MARK: - State milestones

    /// Stores a `state` milestone for each session whose resolved state text
    /// changed since its last stored one, and marks those sessions changed.
    /// Whether anything was stored.
    private func observeStates(_ listed: [SessionReportSlice.Windowed]) -> Bool {
        guard let changedAt = state.withLock({ state -> Date? in
            defer { state.statesChangedAt = nil }
            return state.statesChangedAt
        }) else { return false }
        do {
            let latest = try sidecar.stateMilestones().compactMapValues(\.first)
            let cutoff = now().addingTimeInterval(-HubSyncState.milestoneLifetime)
            var transitions: [Int64] = []
            var stored = false
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
                stored = true
            }
            state.withLock { [transitions] state in
                for id in transitions { state.entries[id, default: Entry()].stateChanged = true }
            }
            return stored
        } catch {
            logger.error("session report: storing state milestones failed: \(error.localizedDescription, privacy: .public)")
            // Resolved again at the next pass.
            state.withLock { $0.statesChangedAt = $0.statesChangedAt ?? changedAt }
            return false
        }
    }

    /// Drops the stored reports of sessions that left the window and the
    /// milestones past 14 days or a session's newest 100. Whether a stored
    /// report was dropped.
    private func prune(keeping ids: Set<Int64>) -> Bool {
        do {
            let before = Set(try sidecar.sessionReports().keys)
            try sidecar.removeSessionReports(keeping: ids)
            try sidecar.pruneSessionMilestones(olderThan: now().addingTimeInterval(-HubSyncState.milestoneLifetime))
            return !before.isSubset(of: ids)
        } catch {
            logger.error("session report: pruning the sidecar failed: \(error.localizedDescription, privacy: .public)")
            return false
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
        /// Whether a changed report was stored (a failure keeps the stored
        /// one and counts as finished).
        case finished(stored: Bool)
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
                return .finished(stored: try sidecar.saveSessionReport(try SessionReportSlice.encode(report), sessionID: id, at: now()))
            } catch {
                logger.error("storing the session report of \(id) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return .finished(stored: false)
    }

    // MARK: - HubCompanion

    func start() {
        generation.withLock { $0 += 1 }
        // States may have changed while the hub was off.
        sessionStatesChanged()
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
