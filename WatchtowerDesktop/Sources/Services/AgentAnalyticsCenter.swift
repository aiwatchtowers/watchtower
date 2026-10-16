import Foundation
import Observation
import WatchtowerCore

/// The agent analytics report (#298), run through `watchtower agents report`:
/// - a workbench's overview (`--workbench N --json --days D`) while its
///   Analytics pane is shown: at once on `show`, again on a period change,
///   then every 60 s while the Workbench tab is on screen;
/// - one session's detail (`--session <uuid>`) on demand (`loadSession`).
///
/// `turnOn` runs `watchtower agents enable`, which loads the history
/// synchronously and may take tens of seconds, then reloads the overview.
///
/// Same run discipline as `SessionReportCenter`: at most one run per key in
/// flight plus one queued rerun, a failed run keeps the last good value
/// marked stale with the error line. Owned by `AppState`, so the values
/// survive navigation; `stop()` cancels every run, which terminates its child.
@MainActor
@Observable
final class AgentAnalyticsCenter {
    nonisolated static let interval: Duration = .seconds(60)

    /// The report window; the raw value is the CLI's `--days` (0 = all).
    enum Period: Int, CaseIterable {
        case week = 7
        case month = 30
        case all = 0
    }

    private(set) var overviews: [Int64: SessionReportCenter.Snapshot<AgentReportOverview>] = [:]
    /// Session details, keyed by session uuid.
    private(set) var sessions: [String: SessionReportCenter.Snapshot<AgentSessionDetail>] = [:]
    /// The workbenches whose `agents enable` is running.
    private(set) var enabling: Set<Int64> = []

    /// Whether the Workbench tab is what the owner sees; the 60 s tick runs
    /// only then (`show`, a period change and `loadSession` are not gated).
    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }

    private enum RunKey: Hashable {
        case overview(workbench: Int64)
        case detail(workbench: Int64, uuid: String)
    }

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let interval: Duration
    /// The workbenches whose pane is shown, with the period asked for.
    @ObservationIgnored private var shown: [Int64: Period] = [:]
    /// The period of the last overview run per workbench: a reload after
    /// Turn On uses it when the pane has since gone.
    @ObservationIgnored private var lastPeriod: [Int64: Period] = [:]
    @ObservationIgnored private var inFlight: [RunKey: (token: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var runsStarted = 0
    @ObservationIgnored private var queued: Set<RunKey> = []
    @ObservationIgnored private var enableRuns: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// A decode error is logged once per streak of failures.
    @ObservationIgnored private var failing: Set<RunKey> = []

    init(runner: any CLIRunnerProtocol, interval: Duration = AgentAnalyticsCenter.interval) {
        self.runner = runner
        self.interval = interval
    }

    /// Whether the 60 s loop is running (a test seam).
    var isPolling: Bool { loop != nil }

    /// The workbench's Analytics pane is on screen: its overview runs now
    /// (when newly shown or the period changed), then every 60 s until `hide`.
    func show(workbench: Int64, period: Period) {
        let changed = shown[workbench] != period
        shown[workbench] = period
        lastPeriod[workbench] = period
        if changed { request(.overview(workbench: workbench)) }
        guard loop == nil else { return }
        loop = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// The pane left the screen; the last loop stops with it.
    func hide(workbench: Int64) {
        shown[workbench] = nil
        queued.remove(.overview(workbench: workbench))
        if shown.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }

    /// Loads one session's detail now, or once more after the run in flight.
    func loadSession(workbench: Int64, uuid: String) {
        request(.detail(workbench: workbench, uuid: uuid))
    }

    /// `watchtower agents enable`, then the overview reload. A failure leaves
    /// its error line on the workbench's overview.
    func turnOn(workbench: Int64) async {
        guard !enabling.contains(workbench) else { return }
        enabling.insert(workbench)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.enable(workbench: workbench)
        }
        enableRuns[workbench] = task
        await task.value
        enableRuns[workbench] = nil
        enabling.remove(workbench)
    }

    /// Stops the loop and cancels every run in flight — the app quits.
    func stop() {
        loop?.cancel()
        loop = nil
        shown.removeAll()
        queued.removeAll()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        enableRuns.values.forEach { $0.cancel() }
        enableRuns.removeAll()
    }

    // MARK: - Runs

    private func tick() {
        guard isTabOnScreen() else { return }
        for workbench in shown.keys { request(.overview(workbench: workbench)) }
    }

    private func enable(workbench: Int64) async {
        let args = ["agents", "enable", "--workbench", String(workbench), "--json"]
        do {
            _ = try await runner.run(args: args)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            overviews[workbench, default: SessionReportCenter.Snapshot()].error = SessionReportCenter.errorLine(error)
            return
        }
        guard !Task.isCancelled else { return }
        let key = RunKey.overview(workbench: workbench)
        request(key)
        // The reload in flight may predate the enable: wait out its queued
        // rerun too.
        while let run = inFlight[key]?.task, !Task.isCancelled { await run.value }
    }

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
        case let .overview(workbench):
            await runOverview(workbench: workbench, key: key)
        case let .detail(workbench, uuid):
            await runDetail(workbench: workbench, uuid: uuid, key: key)
        }
    }

    private func runOverview(workbench: Int64, key: RunKey) async {
        let period = shown[workbench] ?? lastPeriod[workbench] ?? .week
        let args = [
            "agents", "report", "--workbench", String(workbench), "--json", "--days", String(period.rawValue)
        ]
        do {
            let overview = try await decode(AgentReportOverview.self, args: args, key: key)
            // A run `stop()` cancelled applies nothing, whatever the runner returned.
            guard !Task.isCancelled else { return }
            overviews[workbench] = SessionReportCenter.Snapshot(value: overview)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            overviews[workbench, default: SessionReportCenter.Snapshot()].error = SessionReportCenter.errorLine(error)
        }
    }

    private func runDetail(workbench: Int64, uuid: String, key: RunKey) async {
        let args = ["agents", "report", "--workbench", String(workbench), "--json", "--session", uuid]
        do {
            let detail = try await decode(AgentSessionDetail.self, args: args, key: key)
            guard !Task.isCancelled else { return }
            sessions[uuid] = SessionReportCenter.Snapshot(value: detail)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            sessions[uuid, default: SessionReportCenter.Snapshot()].error = SessionReportCenter.errorLine(error)
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
                print("[AgentAnalytics] \(CLILog.label(args)) decode error: \(error.localizedDescription)")
            }
            throw error
        }
    }
}
