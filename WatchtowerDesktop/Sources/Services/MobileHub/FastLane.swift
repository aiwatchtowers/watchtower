import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The trigger side of the hub's fast lane (mobile POC spec §4.5): what
/// nudges `SlicePublisher`, whose one loop coalesces the nudges for 1 s and
/// keeps two fast sends at least 2 s apart. Two sources:
/// - `SessionAgentStateCenter.onChange` and `onRead`, chained onto the
///   closures `initWorkbenches` set (the PROJ-12 held-answer wiring), never
///   replacing them. A change nudges `terminal_session` and `workbench`
///   (its `session_counts`) and asks the changed sessions' workbenches for
///   a git and a report-summary refresh;
/// - GRDB `ValueObservation` over `owner_asks`, `terminal_sessions`,
///   `project_comments` and `targets`. It sees only the Desktop's own
///   writes: Go writes through another connection, and those reach the
///   phone through the center's 1 s poll or the 10 s tick.
///
/// It also copies `TerminalCenter`'s liveness into `SessionLivenessBox` for
/// the `terminal_session` slice, which resolves states off the main actor.
///
/// Main-actor, because the center and the terminal center are. A hub
/// companion: `MobileHubService` (main actor) starts it with the publisher
/// and stops it with the hub.
@MainActor
final class FastLane: HubCompanion {
    /// Each observed table and the kinds its writes nudge. `targets` is
    /// observed as a whole: GRDB tracks tables, not `WHERE project_id IS NOT
    /// NULL`, and a personal target's write only costs one empty diff.
    nonisolated static let observedTables: [(table: String, kinds: Set<SliceKind>)] = [
        ("owner_asks", [.ownerAsk, .terminalSession, .workbench, .workbenchTarget]),
        ("terminal_sessions", [.terminalSession, .workbench, .workbenchTarget]),
        ("project_comments", [.workbenchComment, .workbenchTarget]),
        ("targets", [.workbenchTarget, .workbench])
    ]

    /// What a session state change nudges.
    nonisolated static let sessionStateKinds: Set<SliceKind> = [.terminalSession, .workbench]

    private let dbPool: DatabasePool
    private weak var agentStates: SessionAgentStateCenter?
    private weak var terminalCenter: TerminalCenter?
    private let liveness: SessionLivenessBox
    private let nudge: @Sendable (Set<SliceKind>) -> Void
    private let sessionStateChanged: (Int64) -> Void
    private let logger = Logger(subsystem: Constants.bundleID, category: "FastLane")

    private var previousOnChange: (() -> Void)?
    private var previousOnRead: (() -> Void)?
    private var lastStatuses: [Int64: SessionAgentStatus] = [:]
    private var observations: [Task<Void, Never>] = []
    /// Tables whose observation delivered its initial value (a test seam).
    private(set) var observedTables = 0
    private(set) var isRunning = false

    /// - Parameters:
    ///   - nudge: the publisher's `nudge(kinds:)`.
    ///   - sessionStateChanged: a session of this workbench changed state
    ///     (the git refresher and the report summary runner).
    init(
        dbPool: DatabasePool,
        agentStates: SessionAgentStateCenter?,
        terminalCenter: TerminalCenter?,
        liveness: SessionLivenessBox,
        nudge: @escaping @Sendable (Set<SliceKind>) -> Void,
        sessionStateChanged: @escaping (Int64) -> Void
    ) {
        self.dbPool = dbPool
        self.agentStates = agentStates
        self.terminalCenter = terminalCenter
        self.liveness = liveness
        self.nudge = nudge
        self.sessionStateChanged = sessionStateChanged
    }

    // MARK: - HubCompanion

    /// The hub calls it on the main actor.
    nonisolated func start() {
        MainActor.assumeIsolated { begin() }
    }

    nonisolated func stop() {
        MainActor.assumeIsolated { end() }
    }

    private func begin() {
        guard !isRunning else { return }
        isRunning = true
        if let center = agentStates {
            let previousChange = center.onChange
            let previousRead = center.onRead
            previousOnChange = previousChange
            previousOnRead = previousRead
            center.onChange = { [weak self] in
                previousChange?()
                self?.statesChanged()
            }
            center.onRead = { [weak self] in
                previousRead?()
                self?.statesRead()
            }
            lastStatuses = center.statuses
        }
        copyLiveness()
        // The publisher's first cycle may have run before the liveness copy.
        nudge(Self.sessionStateKinds)
        observations = Self.observedTables.map { observe($0.table, kinds: $0.kinds) }
    }

    /// Unhooks the lane: the center gets back the closures it had before
    /// `begin()` (nothing chains after the hub; a rebuilt hub chains anew).
    private func end() {
        guard isRunning else { return }
        isRunning = false
        if let center = agentStates {
            center.onChange = previousOnChange
            center.onRead = previousOnRead
        }
        previousOnChange = nil
        previousOnRead = nil
        observations.forEach { $0.cancel() }
        observations = []
        observedTables = 0
    }

    // MARK: - Session states

    private func statesChanged() {
        guard isRunning, let center = agentStates else { return }
        let next = center.statuses
        var workbenches: Set<Int64> = []
        for id in Set(next.keys).union(lastStatuses.keys) where next[id] != lastStatuses[id] {
            if let workbench = next[id]?.workbenchID ?? lastStatuses[id]?.workbenchID { workbenches.insert(workbench) }
        }
        lastStatuses = next
        copyLiveness()
        workbenches.sorted().forEach(sessionStateChanged)
        nudge(Self.sessionStateKinds)
    }

    /// An unchanged read may still follow a liveness change the statuses do
    /// not show (a session not among them).
    private func statesRead() {
        guard isRunning, copyLiveness() else { return }
        nudge(Self.sessionStateKinds)
    }

    @discardableResult
    private func copyLiveness() -> Bool {
        guard let terminalCenter else { return false }
        return liveness.update(SessionLiveness(liveIDs: terminalCenter.liveIDs, startedAt: terminalCenter.startedAt))
    }

    // MARK: - Tables

    private func observe(_ table: String, kinds: Set<SliceKind>) -> Task<Void, Never> {
        let observation = ValueObservation.tracking(regions: [Table(table)]) { _ in 0 }
        let dbPool = self.dbPool
        return Task { [weak self] in
            var initial = true
            do {
                for try await _ in observation.values(in: dbPool) {
                    guard !Task.isCancelled, let self, self.isRunning else { break }
                    if initial {
                        initial = false
                        self.observedTables += 1
                        continue
                    }
                    self.nudge(kinds)
                }
            } catch {
                self?.logger.error("observing \(table, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
