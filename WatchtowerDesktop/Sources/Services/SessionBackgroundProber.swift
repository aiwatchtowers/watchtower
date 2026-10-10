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
/// runs clears that. Every bookkeeping entry is in memory only.
@MainActor
final class SessionBackgroundProber {
    /// How soon a probe that could not run is tried again.
    nonisolated static let retryAfter: TimeInterval = 60
    /// Failed probes in a row for one count that show it over.
    nonisolated static let failuresShownOver = 2

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
        now: Date
    ) {
        for row in rows where inFlight[row.id] == nil {
            guard let status = statuses[row.id], let workbench = row.projectID, let agents = row.agentBackground,
                  let count = Self.count(of: row, live: status.state.live, startedAt: startedAt[row.id]),
                  let reported = SessionAgentStatus.parseStamp(count.stamp),
                  showsCount(status, overShown: (entries[row.id]?.failures ?? 0) >= Self.failuresShownOver),
                  policy.needsProbe(count: agents, lastReport: reported, now: now) else { continue }
            var entry = entries[row.id].flatMap { $0.count == count ? $0 : nil }
                ?? Entry(count: count, lastProbe: .distantPast, failures: 0)
            let wait = entry.failures > 0 ? Self.retryAfter : SessionBackgroundPolicy.staleAfter
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
    }

    /// Agents working, or the same count shown over after failed probes —
    /// at the session's prompt either way, so never Needs approval.
    private func showsCount(_ status: SessionAgentStatus, overShown: Bool) -> Bool {
        guard status.isAtPrompt, status.state.kind != .failed else { return false }
        return status.state.kind == .background || overShown
    }

    private func start(session: Int64, workbench: Int64, count: Count) {
        probesStarted += 1
        let token = probesStarted
        let task = Task { [weak self] in
            await self?.probe(session: session, workbench: workbench, count: count)
            self?.finished(session, token: token)
        }
        inFlight[session] = (token, task)
    }

    private func finished(_ session: Int64, token: Int) {
        guard inFlight[session]?.token == token else { return }
        inFlight[session] = nil
    }

    private func probe(session: Int64, workbench: Int64, count: Count) async {
        let args = ["workbench", "session-probe", "--workbench", String(workbench), "--session", String(session)]
        let failure: String?
        var ended = false
        var outcome: SessionProbeResult.Outcome?
        do {
            let data = try await runner.run(args: args)
            let result = try JSONDecoder().decode(SessionProbeResult.self, from: data)
            failure = result.ran ? nil : (result.error ?? "no outcome")
            ended = result.ended
            outcome = result.outcome
        } catch {
            // A DecodingError's localizedDescription drops the key path.
            failure = error is DecodingError ? String(describing: error) : error.localizedDescription
        }
        // A probe `stop()` cancelled applies nothing.
        guard !Task.isCancelled, var entry = entries[session], entry.count == count else { return }
        let wasOver = entry.failures >= Self.failuresShownOver
        if let failure {
            entry.failures += 1
            let shownOver = entry.failures == Self.failuresShownOver ? ", count shown over" : ""
            print("[SessionProbe] session \(session): probe failed (\(entry.failures) in a row\(shownOver)): \(failure)")
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
