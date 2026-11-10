import Foundation
import WatchtowerCore

/// When the Desktop runs `watchtower workbench session-probe` for a session
/// whose background agent count went silent, and what it shows when the
/// probe cannot run (spec 2026-10-10-session-background-agents §10,
/// PROJ-11). Owned by `SessionAgentStateCenter`, which hands it every
/// resolved read.
///
/// A session is probed while it shows Agents working (live, at its prompt,
/// not Needs approval) with a count above zero whose report is at least
/// `SessionBackgroundPolicy.staleAfter` old; the CLI checks the same again
/// and is the only writer — it ends the count on the registry's verdict.
/// One probe per count (the session's run and its report stamp) per
/// `staleAfter`, so a `busy` answer is asked again after another 30 minutes
/// of silence; a probe that could not run is tried again after
/// `retryAfter`. Two failed probes in a row for the same count show it over
/// (`displayOver`), with no write; a new report, a new run or a probe that
/// runs clears that. Once shown over, the count is tried again only every
/// `staleAfter`, so a failure that persists (a registry format change) costs
/// one CLI child per 30 minutes, not one a minute; the log names the first
/// failure of a streak and the flip to over, not every retry. Every
/// bookkeeping entry is in memory only.
///
/// The same probe is the bridge for a live session whose agent's failed
/// turn is read from its rollout (`AgentSessionCaps.rolloutWatch`, Codex:
/// no `StopFailure` hook, no Stop on a failed turn; board #959, PROJ-11) and
/// reads Working, when the session host does not watch it itself
/// (`hostWatched`: a host older than spec 2026-11-05 §3.5's watch, G5): the
/// CLI reads the turn's end from the rollout and stores the Error state, or
/// marks a rollout it cannot read not watched. One check per session per
/// `codexTurnCheckEvery` (a CLI child each time); a `failed` or
/// `not_watched` answer reads the rows again. A check that cannot run is
/// logged once per streak and tried again only after `retryAfter`.
@MainActor
final class SessionBackgroundProber {
    /// How soon a probe that could not run is tried again.
    nonisolated static let retryAfter: TimeInterval = 60
    /// Failed probes in a row for one count that show it over.
    nonisolated static let failuresShownOver = 2
    /// How often a working Codex session is checked for a failed turn.
    nonisolated static let codexTurnCheckEvery: TimeInterval = 5

    /// A probe ended a count, or what shows as over changed: the center
    /// reads the rows again. One subscriber.
    var onSettled: (() -> Void)?

    /// The count a probe is about: the session's run and the count's report
    /// stamp. A new report or a new run is a new count.
    private struct Count: Equatable {
        let run: Date
        let stamp: String
    }

    private struct Entry {
        let count: Count
        /// When the last probe of this count started.
        var lastProbe: Date
        /// Failed probes of this count in a row; 0 after one that ran.
        var failures: Int
    }

    private let runner: any CLIRunnerProtocol
    private let policy: SessionBackgroundPolicy
    /// Keyed by `terminal_sessions.id`.
    private var entries: [Int64: Entry] = [:]
    /// The probe in flight per session, with its token: a probe that `stop()`
    /// cancelled never clears a later one's entry.
    private var inFlight: [Int64: (token: Int, task: Task<Void, Never>)] = [:]
    private var probesStarted = 0
    /// When each working Codex session's last turn check started.
    private var codexChecks: [Int64: Date] = [:]
    /// Codex sessions whose last turn check could not run (logged once).
    private var codexCheckFailing: Set<Int64> = []

    init(runner: any CLIRunnerProtocol, policy: SessionBackgroundPolicy = .current) {
        self.runner = runner
        self.policy = policy
    }

    /// Whether a probe of `sessionID` is running (a test seam).
    func isProbing(_ sessionID: Int64) -> Bool { inFlight[sessionID] != nil }

    /// The sessions whose count shows as over after failed probes. Drops the
    /// bookkeeping of every count that is no longer the row's — the session
    /// stopped, started again or reported anew.
    func displayOver(_ rows: [SessionAgentStateRow], liveIDs: Set<Int64>, startedAt: [Int64: Date]) -> Set<Int64> {
        let current = Dictionary(rows.map { ($0.id, $0) }) { _, last in last }
        entries = entries.filter { id, entry in
            guard let row = current[id] else { return false }
            return Self.count(of: row, live: liveIDs.contains(id), startedAt: startedAt[id]) == entry.count
        }
        return Set(entries.filter { $0.value.failures >= Self.failuresShownOver }.keys)
    }

    /// Starts a probe for every session in `statuses` whose count is due at
    /// `now`; `rows` and `startedAt` are what `statuses` were resolved from.
    func probeDue(
        _ rows: [SessionAgentStateRow],
        statuses: [Int64: SessionAgentStatus],
        startedAt: [Int64: Date],
        now: Date,
        hostWatched: Set<Int64> = []
    ) {
        checkCodexTurns(rows, statuses: statuses, now: now, hostWatched: hostWatched)
        for row in rows where inFlight[row.id] == nil {
            guard let status = statuses[row.id], let workbench = row.projectID, let agents = row.agentBackground,
                  let count = Self.count(of: row, live: status.state.live, startedAt: startedAt[row.id]),
                  let reported = SessionAgentStatus.parseStamp(count.stamp),
                  showsCount(status, overShown: (entries[row.id]?.failures ?? 0) >= Self.failuresShownOver),
                  policy.needsProbe(
                      count: agents, shells: row.agentBackgroundShells ?? 0, lastReport: reported, now: now
                  ) else { continue }
            var entry = entries[row.id].flatMap { $0.count == count ? $0 : nil }
                ?? Entry(count: count, lastProbe: .distantPast, failures: 0)
            let retrying = entry.failures > 0 && entry.failures < Self.failuresShownOver
            let wait = retrying ? Self.retryAfter : SessionBackgroundPolicy.staleAfter
            guard now.timeIntervalSince(entry.lastProbe) >= wait else { continue }
            entry.lastProbe = now
            entries[row.id] = entry
            start(session: row.id, workbench: workbench, count: count)
        }
    }

    /// Cancels every probe in flight (its child gets SIGTERM) and forgets
    /// the bookkeeping.
    func stop() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight = [:]
        entries = [:]
        codexChecks = [:]
        codexCheckFailing = []
    }

    /// Starts a turn check for every live rollout-watched session the host
    /// does not watch that reads Working and was not checked in the last
    /// `codexTurnCheckEvery`; forgets the sessions that no longer qualify.
    private func checkCodexTurns(
        _ rows: [SessionAgentStateRow], statuses: [Int64: SessionAgentStatus], now: Date, hostWatched: Set<Int64>
    ) {
        var working: Set<Int64> = []
        for row in rows where row.agent.map({ AgentSessionCaps.of($0).rolloutWatch }) == true
            && !hostWatched.contains(row.id) {
            guard let status = statuses[row.id], let workbench = row.projectID,
                  status.state.live, status.state.kind == .working else { continue }
            working.insert(row.id)
            let every = codexCheckFailing.contains(row.id) ? Self.retryAfter : Self.codexTurnCheckEvery
            guard inFlight[row.id] == nil,
                  now.timeIntervalSince(codexChecks[row.id] ?? .distantPast) >= every else { continue }
            codexChecks[row.id] = now
            launch(session: row.id) { [weak self] in
                await self?.checkCodexTurn(session: row.id, workbench: workbench)
            }
        }
        codexChecks = codexChecks.filter { working.contains($0.key) }
        codexCheckFailing.formIntersection(working)
    }

    private func checkCodexTurn(session: Int64, workbench: Int64) async {
        let run = await runProbe(session: session, workbench: workbench)
        guard !Task.isCancelled else { return }
        switch run {
        case let .failed(failure):
            if codexCheckFailing.insert(session).inserted {
                print("[SessionProbe] session \(session): codex turn check failed: \(failure)")
            }
        case let .ran(result):
            if codexCheckFailing.remove(session) != nil {
                print("[SessionProbe] session \(session): codex turn check runs again")
            }
            switch result.outcome {
            case .failed:
                print("[SessionProbe] session \(session): the codex turn failed")
                onSettled?()
            case .notWatched:
                print("[SessionProbe] session \(session): the codex rollout is not watched")
                onSettled?()
            default:
                break
            }
        }
    }

    /// One `session-probe` run: its answer when it ran, else why not.
    private enum ProbeRun {
        case ran(SessionProbeResult)
        case failed(String)
    }

    private func runProbe(session: Int64, workbench: Int64) async -> ProbeRun {
        let args = ["workbench", "session-probe", "--workbench", String(workbench), "--session", String(session)]
        do {
            let data = try await runner.run(args: args)
            let result = try JSONDecoder().decode(SessionProbeResult.self, from: data)
            return result.ran ? .ran(result) : .failed(result.error ?? "no outcome")
        } catch {
            // A DecodingError's localizedDescription drops the key path.
            return .failed(error is DecodingError ? String(describing: error) : error.localizedDescription)
        }
    }

    /// Agents working, or the same count shown over after failed probes —
    /// at the session's prompt either way, so never Needs approval.
    private func showsCount(_ status: SessionAgentStatus, overShown: Bool) -> Bool {
        guard status.isAtPrompt, status.state.kind != .failed else { return false }
        return status.state.kind == .background || overShown
    }

    private func start(session: Int64, workbench: Int64, count: Count) {
        launch(session: session) { [weak self] in
            await self?.probe(session: session, workbench: workbench, count: count)
        }
    }

    /// Runs `body` as the session's one probe in flight.
    private func launch(session: Int64, _ body: @escaping @MainActor () async -> Void) {
        probesStarted += 1
        let token = probesStarted
        let task = Task { [weak self] in
            await body()
            self?.finished(session, token: token)
        }
        inFlight[session] = (token, task)
    }

    private func finished(_ session: Int64, token: Int) {
        guard inFlight[session]?.token == token else { return }
        inFlight[session] = nil
    }

    private func probe(session: Int64, workbench: Int64, count: Count) async {
        let failure: String?
        var ended = false
        var outcome: SessionProbeResult.Outcome?
        switch await runProbe(session: session, workbench: workbench) {
        case let .ran(result):
            failure = nil
            ended = result.ended
            outcome = result.outcome
        case let .failed(reason):
            failure = reason
        }
        // A probe `stop()` cancelled applies nothing.
        guard !Task.isCancelled, var entry = entries[session], entry.count == count else { return }
        let wasOver = entry.failures >= Self.failuresShownOver
        if let failure {
            entry.failures += 1
            // Logged once per streak, and once more when the count flips to over.
            if entry.failures == 1 {
                print("[SessionProbe] session \(session): probe failed: \(failure)")
            } else if entry.failures == Self.failuresShownOver {
                print("[SessionProbe] session \(session): probe failed again, count shown over: \(failure)")
            }
        } else {
            entry.failures = 0
            if ended { print("[SessionProbe] session \(session): \(outcome?.rawValue ?? "?") ended the count") }
        }
        entries[session] = entry
        if ended || wasOver != (entry.failures >= Self.failuresShownOver) { onSettled?() }
    }

    /// The count of `row` for a live session of a known run; nil without a
    /// report stamp.
    private static func count(of row: SessionAgentStateRow, live: Bool, startedAt: Date?) -> Count? {
        guard live, let startedAt, let stamp = row.agentBackgroundAt, !stamp.isEmpty else { return nil }
        return Count(run: startedAt, stamp: stamp)
    }
}
