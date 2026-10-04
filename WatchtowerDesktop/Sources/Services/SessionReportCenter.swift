import AppKit
import Foundation
import Observation
import WatchtowerCore

/// The workbench session report (spec 2026-10-03-workbench-session-report,
/// Part 7), run through `watchtower workbench session-report`:
/// - the session rows' report line (`--summary --json`) for the workbench on
///   screen, every 15 s while the Workbench tab is visible and on app
///   activation; the view asks for one more run when a workbench comes on
///   screen (`refresh(workbench:)`);
/// - the full report (`--session S --json`) of the session whose Session view
///   is shown: on `show`, every 30 s while shown and the tab is visible, at
///   once when the tab comes back on screen (app activation, a window
///   uncovered), and whenever that session's agent state changes.
///
/// At most one run of each kind is in flight per workbench, plus one queued
/// rerun; asking again while one is queued adds nothing. A failed run keeps
/// the last good value, marked stale with the error line. Owned by
/// `AppState`, so the values survive navigation; `stop()` cancels every run,
/// which terminates its child.
@MainActor
@Observable
final class SessionReportCenter {
    nonisolated static let summaryInterval: Duration = .seconds(15)
    nonisolated static let reportInterval: Duration = .seconds(30)

    /// The last good value and, when the run after it failed, that run's
    /// error line.
    struct Snapshot<Value: Equatable>: Equatable {
        /// nil until a run succeeds.
        var value: Value?
        /// The last run's error line; nil when it succeeded.
        var error: String?

        /// The value is from an earlier run: the last one failed.
        var isStale: Bool { error != nil }
    }

    /// The session whose Session view is on screen.
    struct ShownSession: Equatable {
        let session: Int64
        let workbench: Int64
    }

    /// The report lines of each workbench's `claude` sessions, keyed by
    /// workbench id, then by session id.
    private(set) var summaries: [Int64: Snapshot<[Int64: SessionReportSummary]>] = [:]
    /// Full reports, keyed by session id.
    private(set) var reports: [Int64: Snapshot<SessionReport>] = [:]
    private(set) var shown: ShownSession?

    /// Whether the Workbench tab is what the owner sees; the 15 s and 30 s
    /// ticks run only then (`show`, `refresh` and an agent-state change are
    /// not gated).
    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }
    /// The workbench on screen, whose rows the poll and activation refresh.
    @ObservationIgnored var watchedWorkbenchID: () -> Int64? = { nil }
    /// A session's agent state, read under observation: a change reruns the
    /// shown session's report.
    @ObservationIgnored var agentState: (Int64) -> SessionSwitcherPresentation.State? = { _ in nil }

    private enum RunKey: Hashable {
        case summary(workbench: Int64)
        case report(workbench: Int64)
    }

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let summaryInterval: Duration
    @ObservationIgnored private let reportInterval: Duration
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// The run in flight per key, with its token: a run cancelled by `stop()`
    /// never clears a later one's entry.
    @ObservationIgnored private var inFlight: [RunKey: (token: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var runsStarted = 0
    @ObservationIgnored private var queued: Set<RunKey> = []
    @ObservationIgnored private var summaryLoop: Task<Void, Never>?
    @ObservationIgnored private var reportLoop: Task<Void, Never>?
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var occlusionObserver: NSObjectProtocol?
    /// Whether the shown report was on screen at the last look (`show`, a
    /// tick, a screen change): coming back on screen refreshes it at once.
    @ObservationIgnored private var reportWasOnScreen = false
    /// Bumped on every show/hide: an observation armed for an earlier shown
    /// session stops re-arming.
    @ObservationIgnored private var followGeneration = 0
    @ObservationIgnored private var followedState: SessionSwitcherPresentation.State?
    /// A decode error is logged once per streak of failures (the runner logs
    /// a failed exit itself).
    @ObservationIgnored private var failing: Set<RunKey> = []

    init(
        runner: any CLIRunnerProtocol,
        summaryInterval: Duration = SessionReportCenter.summaryInterval,
        reportInterval: Duration = SessionReportCenter.reportInterval,
        notificationCenter: NotificationCenter = .default
    ) {
        self.runner = runner
        self.summaryInterval = summaryInterval
        self.reportInterval = reportInterval
        self.notificationCenter = notificationCenter
    }

    /// Whether the 15 s loop is running (a test seam).
    var isPollingSummaries: Bool { summaryLoop != nil }
    /// Whether the shown session's 30 s loop is running (a test seam).
    var isPollingReport: Bool { reportLoop != nil }

    /// Starts the 15 s poll, the activation refresh and the screen watch.
    func start() {
        guard summaryLoop == nil else { return }
        summaryLoop = Task { [weak self, summaryInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: summaryInterval)
                guard !Task.isCancelled, let self else { return }
                self.pollSummaries()
            }
        }
        activationObserver = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.screenMayHaveChanged()
                if let id = self.watchedWorkbenchID() { self.refresh(workbench: id) }
            }
        }
        occlusionObserver = notificationCenter.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenMayHaveChanged() }
        }
    }

    /// Stops every loop and cancels every run in flight — the app quits.
    func stop() {
        summaryLoop?.cancel()
        summaryLoop = nil
        reportLoop?.cancel()
        reportLoop = nil
        followGeneration += 1
        if let activationObserver { notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        if let occlusionObserver { notificationCenter.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        queued.removeAll()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    /// One poll tick: the watched workbench's rows, only while the tab is on
    /// screen.
    func pollSummaries() {
        guard isTabOnScreen(), let id = watchedWorkbenchID() else { return }
        refresh(workbench: id)
    }

    /// Runs the workbench's summary now, or once more after the run in flight.
    func refresh(workbench: Int64) {
        request(.summary(workbench: workbench))
    }

    /// The Session view shows `session`: its report runs now, then every 30 s
    /// and on each change of its agent state, until `hide`. A run still in
    /// flight for the session shown before is not cancelled; its result is
    /// dropped.
    func show(session: Int64, workbench: Int64) {
        let next = ShownSession(session: session, workbench: workbench)
        guard shown != next else { return }
        shown = next
        followGeneration += 1
        followedState = agentState(session)
        followAgentState(followGeneration)
        // Shown by a view coming on screen; the run below is the fresh one.
        reportWasOnScreen = true
        request(.report(workbench: workbench))
        reportLoop?.cancel()
        reportLoop = Task { [weak self, reportInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: reportInterval)
                guard !Task.isCancelled, let self else { return }
                // A Session view left open in a hidden, covered or
                // backgrounded window never disappears: its ticks run nothing.
                let onScreen = self.isTabOnScreen()
                self.reportWasOnScreen = onScreen
                guard onScreen else { continue }
                self.refreshShownReport()
            }
        }
    }

    /// The Session view of `session` left the screen.
    func hide(session: Int64) {
        guard shown?.session == session else { return }
        shown = nil
        followGeneration += 1
        reportLoop?.cancel()
        reportLoop = nil
    }

    /// Runs the shown session's report now, or once more after the run in
    /// flight.
    func refreshShownReport() {
        guard let shown else { return }
        request(.report(workbench: shown.workbench))
    }

    /// The app came forward or a window was covered or uncovered: a shown
    /// report back on screen runs now instead of at the next tick.
    func screenMayHaveChanged() {
        guard shown != nil else { return }
        let onScreen = isTabOnScreen()
        defer { reportWasOnScreen = onScreen }
        if onScreen, !reportWasOnScreen { refreshShownReport() }
    }

    // MARK: - Agent state

    private func followAgentState(_ generation: Int) {
        guard generation == followGeneration, let shown else { return }
        let state = withObservationTracking {
            agentState(shown.session)
        } onChange: { [weak self] in
            Task { @MainActor in self?.followAgentState(generation) }
        }
        guard state != followedState else { return }
        followedState = state
        request(.report(workbench: shown.workbench))
    }

    // MARK: - Runs

    private func request(_ key: RunKey) {
        guard inFlight[key] == nil else {
            queued.insert(key)
            return
        }
        runsStarted += 1
        let token = runsStarted
        let task = Task { [weak self] in
            await self?.perform(key)
            self?.finished(key, token: token)
        }
        inFlight[key] = (token, task)
    }

    private func finished(_ key: RunKey, token: Int) {
        guard inFlight[key]?.token == token else { return }
        inFlight[key] = nil
        if queued.remove(key) != nil { request(key) }
    }

    private func perform(_ key: RunKey) async {
        switch key {
        case .summary(let workbench):
            await runSummary(workbench: workbench, key: key)
        case .report(let workbench):
            await runReport(workbench: workbench, key: key)
        }
    }

    private func runSummary(workbench: Int64, key: RunKey) async {
        let args = ["workbench", "session-report", "--workbench", String(workbench), "--summary", "--json"]
        do {
            let rows = try await decode([SessionReportSummary].self, args: args, key: key)
            // A run `stop()` cancelled applies nothing, whatever the runner returned.
            guard !Task.isCancelled else { return }
            summaries[workbench] = Snapshot(
                value: Dictionary(rows.map { ($0.sessionID, $0) }) { _, last in last }
            )
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            summaries[workbench, default: Snapshot()].error = Self.errorLine(error)
        }
    }

    private func runReport(workbench: Int64, key: RunKey) async {
        // A rerun queued for a session since hidden, or shown in another
        // workbench, has nothing to run.
        guard let shown, shown.workbench == workbench else { return }
        let session = shown.session
        let args = [
            "workbench", "session-report", "--workbench", String(workbench), "--session", String(session), "--json"
        ]
        do {
            let report = try await decode(SessionReport.self, args: args, key: key)
            guard !Task.isCancelled, self.shown?.session == session else { return }
            reports[session] = Snapshot(value: report)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), self.shown?.session == session else { return }
            reports[session, default: Snapshot()].error = Self.errorLine(error)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, args: [String], key: RunKey) async throws -> T {
        let data = try await runner.run(args: args)
        do {
            let value = try JSONDecoder().decode(type, from: data)
            failing.remove(key)
            return value
        } catch {
            if failing.insert(key).inserted {
                print("[SessionReport] \(CLILog.label(args)) decode error: \(error.localizedDescription)")
            }
            throw error
        }
    }

    /// The first line of the error, what the stale caption carries.
    static func errorLine(_ error: Error) -> String {
        let text = error.localizedDescription
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }
}
