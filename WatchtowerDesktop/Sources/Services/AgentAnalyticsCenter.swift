import Foundation
import Observation
import WatchtowerCore

/// The agent analytics report (#298), run through `watchtower agents report`:
/// - a workbench's overview (`--workbench N --json --days D [--agent A]`)
///   while its Analytics pane is shown: at once on `show`, again on a period
///   or agent filter change, then every 60 s while the Workbench tab is on
///   screen; an answer for a `(period, agent)` the pane has since left is
///   dropped, and a CLI that does not know `--agent` resets the filter to
///   All (`onAgentRefused`);
/// - one session's detail (`--session <uuid>`) on demand (`loadSession`).
///
/// `turnOn` runs `watchtower agents enable` — it switches analytics on, runs
/// a pending one-time move out of watchtower.db and nudges the daemon, which
/// loads the history in the background — then reloads the overview.
///
/// Same run discipline as `SessionReportCenter`: at most one run per key in
/// flight plus one queued rerun, a failed run keeps the last good value
/// marked stale with the error line. Owned by `AppState`, so the values
/// survive navigation; `stop()` cancels every run, which terminates its child.
@MainActor
@Observable
final class AgentAnalyticsCenter {
    nonisolated static let interval: Duration = .seconds(60)

    /// The report window; the raw value is the CLI's `--days`.
    enum Period: Int, CaseIterable {
        case day = 1
        case week = 7
        case month = 30
    }

    /// The agent filter; the raw value is the CLI's `--agent` (#1517).
    enum Agent: String, CaseIterable {
        case all, claude, codex
    }

    /// What the pane asks for: the report's period and agent filter.
    struct Query: Hashable {
        var period: Period
        var agent: Agent = .all
    }

    private(set) var overviews: [Int64: SessionReportCenter.Snapshot<AgentReportOverview>] = [:]
    /// Session details, keyed by session uuid.
    private(set) var sessions: [String: SessionReportCenter.Snapshot<AgentSessionDetail>] = [:]
    /// The workbenches whose `agents enable` is running.
    private(set) var enabling: Set<Int64> = []

    /// Whether the Workbench tab is what the owner sees; the 60 s tick runs
    /// only then (`show`, a period change and `loadSession` are not gated).
    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }
    /// The CLI refused `--agent` (an older CLI): the owner of the filter
    /// puts the workbench's filter back to All.
    @ObservationIgnored var onAgentRefused: (Int64) -> Void = { _ in }

    private enum RunKey: Hashable {
        case overview(workbench: Int64)
        case detail(workbench: Int64, uuid: String)
    }

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let interval: Duration
    /// The workbenches whose pane is shown, with what it asks for.
    @ObservationIgnored private var shown: [Int64: Query] = [:]
    /// The query of the last overview run per workbench: a reload after
    /// Turn On uses it when the pane has since gone.
    @ObservationIgnored private var lastQuery: [Int64: Query] = [:]
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
    /// (when newly shown or the period or agent changed), then every 60 s
    /// until `hide`.
    func show(workbench: Int64, period: Period, agent: Agent = .all) {
        let query = Query(period: period, agent: agent)
        let changed = shown[workbench] != query
        shown[workbench] = query
        lastQuery[workbench] = query
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

    /// Retry on the report's error line: the overview runs once more.
    func retry(workbench: Int64) {
        request(.overview(workbench: workbench))
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
        let query = currentQuery(workbench)
        var args = [
            "agents", "report", "--workbench", String(workbench), "--json", "--days", String(query.period.rawValue)
        ]
        if query.agent != .all { args += ["--agent", query.agent.rawValue] }
        do {
            let overview = try await decode(AgentReportOverview.self, args: args, key: key)
            // A run `stop()` cancelled applies nothing, whatever the runner
            // returned; an answer for a query the pane has since left is
            // dropped (the rerun queued by that change brings the new one).
            guard !Task.isCancelled, currentQuery(workbench) == query else { return }
            // The 60 s tick mostly brings the same report back, only its
            // clock stamps moved: assigning it again would redraw the whole
            // pane. A changed period or a pending error line still applies.
            if let current = overviews[workbench], current.error == nil, let shown = current.value,
               shown.sameReport(as: overview),
               AgentAnalyticsFormat.period(of: shown) == AgentAnalyticsFormat.period(of: overview) {
                return
            }
            overviews[workbench] = SessionReportCenter.Snapshot(value: overview)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError), currentQuery(workbench) == query else { return }
            overviews[workbench, default: SessionReportCenter.Snapshot()].error = SessionReportCenter.errorLine(error)
            if query.agent != .all, Self.refusesAgentFlag(error) {
                // The filter goes back to All here too, so the pane's
                // reset `show` reruns nothing: the error line stays, with
                // Retry, until the owner presses it or the next tick.
                shown[workbench]?.agent = .all
                lastQuery[workbench]?.agent = .all
                onAgentRefused(workbench)
            }
        }
    }

    private func currentQuery(_ workbench: Int64) -> Query {
        shown[workbench] ?? lastQuery[workbench] ?? Query(period: .week)
    }

    /// A CLI older than the agent filter fails `--agent` with cobra's usage
    /// error ("unknown flag: --agent"), a newer one with "--agent must be …".
    private static func refusesAgentFlag(_ error: Error) -> Bool {
        guard case let CLIRunnerError.nonZeroExit(_, stderr) = error else { return false }
        return stderr.contains("--agent")
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
