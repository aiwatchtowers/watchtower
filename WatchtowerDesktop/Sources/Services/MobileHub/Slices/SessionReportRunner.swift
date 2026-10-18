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
/// observation loop. A state change or an accepted phone request wakes the
/// loop (no sooner than 5 s after its last pass, `HubRunnerWake`); otherwise
/// it sleeps until a deferred state-change run is due, at most `Timing.idle`
/// (board #842). The next pass resolves the window's states and stores
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
        /// The longest wait between two passes with no state change or phone
        /// request (board #842); either wakes the loop, at most once per
        /// `HubRunnerWake.standardMinimumGap`.
        let idle: Duration

        static let standard = Self(
            every: .seconds(120), stateSpacing: .seconds(5), requestSpacing: .seconds(60), timeout: .seconds(30), idle: .seconds(15)
        )
    }

    struct Entry {
        var lastAttempt: ContinuousClock.Instant?
        var stateChanged = false
        var networkRequested = false
        var lastRequest: ContinuousClock.Instant?
    }

    struct State {
        var entries: [Int64: Entry] = [:]
        /// When the fast lane first reported a state change the runner has
        /// not resolved yet; nil when there is none.
        var statesChangedAt: Date?
        /// When the earliest state-change run the last pass deferred (inside
        /// `stateSpacing`) is due; nil when it deferred none.
        var nextStateRunDue: ContinuousClock.Instant?
    }

    /// One due run, and what `takeDue` changed, so a pass that did not
    /// finish it can put it back.
    struct Taken {
        let sessionID: Int64
        let workbenchID: Int64
        let network: Bool
        let previous: Entry?
        let stamp: ContinuousClock.Instant
    }

    let fetch: Fetch
    let window: Window
    let sidecar: HubSyncState
    let timing: Timing
    let clock: @Sendable () -> ContinuousClock.Instant
    let now: @Sendable () -> Date
    /// Whether a pass runs at all (the hub's linked-phone gate).
    private let isActive: @Sendable () -> Bool
    let state = OSAllocatedUnfairLock(initialState: State())
    private let wake: HubRunnerWake
    private let loopTask = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// Bumped by `start()` and `stop()`: a pass that began under another
    /// generation stops before its next run and stores nothing.
    let generation = OSAllocatedUnfairLock(initialState: 0)
    let logger = Logger(subsystem: Constants.bundleID, category: "SessionReportRunner")

    /// - Parameters:
    ///   - wake: the loop's wait between passes.
    ///   - window: the report window (`SessionReportSlice.window`).
    init(
        fetch: @escaping Fetch,
        sidecar: HubSyncState,
        timing: Timing = .standard,
        clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        now: @escaping @Sendable () -> Date = { Date() },
        isActive: @escaping @Sendable () -> Bool = { true },
        wake: HubRunnerWake = HubRunnerWake(),
        window: @escaping Window
    ) {
        self.fetch = fetch
        self.window = window
        self.sidecar = sidecar
        self.timing = timing
        self.clock = clock
        self.now = now
        self.isActive = isActive
        self.wake = wake
    }

    /// `SessionReportCenter`'s argv, plus `--no-network` for every run the
    /// phone did not ask for.
    static func arguments(workbenchID: Int64, sessionID: Int64, network: Bool) -> [String] {
        let args = ["workbench", "session-report", "--workbench", String(workbenchID), "--session", String(sessionID), "--json"]
        return network ? args : args + ["--no-network"]
    }

    /// The hub's runner: the CLI through `runner`, over the report window
    /// of `sessions`; no pass runs while `isActive` is false.
    static func live(
        _ runner: any CLIRunnerProtocol,
        dbPool: DatabasePool,
        sessions: TerminalSessionSlice,
        sidecar: HubSyncState,
        isActive: @escaping @Sendable () -> Bool = { true }
    ) -> SessionReportRunner {
        SessionReportRunner(fetch: cliFetch(runner), sidecar: sidecar, isActive: isActive) {
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

    /// The fast lane saw a session state change: wakes the loop, whose pass
    /// resolves the window's states.
    func sessionStatesChanged() {
        markStatesChanged()
        wake.signal()
    }

    private func markStatesChanged() {
        let stamp = now()
        state.withLock { $0.statesChangedAt = $0.statesChangedAt ?? stamp }
    }

    /// The phone's `session_report_request`: a run with the network at the
    /// next pass. False when the session's last accepted request is less
    /// than `requestSpacing` old (nothing more runs).
    @discardableResult
    func requestReport(sessionID: Int64) -> Bool {
        let stamp = clock()
        let accepted = state.withLock { [timing] state in
            var entry = state.entries[sessionID] ?? Entry()
            if let last = entry.lastRequest, stamp - last < timing.requestSpacing { return false }
            entry.lastRequest = stamp
            entry.networkRequested = true
            state.entries[sessionID] = entry
            return true
        }
        if accepted { wake.signal() }
        return accepted
    }

    /// The wait before the next pass: until the earliest state-change run
    /// the last pass deferred, else `idle`. Taken once, so a pass that did
    /// not get to `takeDue` (a failed read) leaves the loop at `idle`.
    private func takeNextWait() -> Duration {
        let due = state.withLock { state -> ContinuousClock.Instant? in
            defer { state.nextStateRunDue = nil }
            return state.nextStateRunDue
        }
        return HubRunnerWake.duration(until: due, now: clock(), idle: timing.idle)
    }

    // MARK: - HubCompanion

    func start() {
        generation.withLock { $0 += 1 }
        // States may have changed while the hub was off; the loop's first
        // pass resolves them, so no wake is needed.
        markStatesChanged()
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
