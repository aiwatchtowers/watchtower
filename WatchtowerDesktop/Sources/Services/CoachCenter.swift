import Foundation
import Observation
import WatchtowerCore

/// The agent coach (#1120), run through `watchtower coach …`: a workbench's
/// metrics (`status --workbench N --days D`) while its Analytics pane is
/// shown, the proposals (`proposals --status all`), and the owner's verbs
/// Accept / Decline / Roll back / Run now.
///
/// Reads follow `AgentAnalyticsCenter`'s discipline: one run per key in
/// flight plus one queued rerun, a 60 s tick only while the Workbench tab is
/// on screen. `runNow`'s CLI call is an unstructured task `stop()` and `hide`
/// never cancel (the CLI finishes on its own, spec §3.3); after `stop()` only
/// the application of its result to state is skipped.
@MainActor
@Observable
final class CoachCenter {
    nonisolated static let interval: Duration = .seconds(60)
    /// `coach run` calls the model; the runner's default timeout is too short.
    nonisolated static let runTimeout: TimeInterval = 900

    private(set) var status: [Int64: SessionReportCenter.Snapshot<CoachStatus>] = [:]
    private(set) var proposals: SessionReportCenter.Snapshot<[CoachProposal]>?
    private(set) var running = false
    private(set) var runLine: String?
    private(set) var cardErrors: [Int64: String] = [:]
    /// Proposals with an owner verb in flight: a second press on the same
    /// card does nothing and the card disables its buttons meanwhile.
    private(set) var pending: Set<Int64> = []

    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }

    private enum RunKey: Hashable {
        case status(workbench: Int64)
        case proposals
    }

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var shown: [Int64: AgentAnalyticsCenter.Period] = [:]
    @ObservationIgnored private var inFlight: [RunKey: (token: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var runsStarted = 0
    @ObservationIgnored private var queued: Set<RunKey> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Bumped by `stop()`: a `runNow` that began earlier applies nothing.
    @ObservationIgnored private var epoch = 0

    init(runner: any CLIRunnerProtocol, interval: Duration = CoachCenter.interval) {
        self.runner = runner
        self.interval = interval
    }

    var isPolling: Bool { loop != nil }

    func show(workbench: Int64, period: AgentAnalyticsCenter.Period) {
        let changed = shown[workbench] != period
        shown[workbench] = period
        if changed {
            request(.status(workbench: workbench))
            if shown.count == 1 { request(.proposals) }
        }
        guard loop == nil else { return }
        loop = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    func hide(workbench: Int64) {
        shown[workbench] = nil
        queued.remove(.status(workbench: workbench))
        if shown.isEmpty {
            loop?.cancel()
            loop = nil
        }
    }

    /// Cancels the reads and the loop — the app quits. A `coach run` child
    /// is left to finish.
    func stop() {
        epoch += 1
        loop?.cancel()
        loop = nil
        shown.removeAll()
        queued.removeAll()
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    // MARK: - Owner verbs

    /// `editedText` is sent over stdin; nil accepts the proposal as written.
    func accept(_ id: Int64, editedText: String?) async {
        guard pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        let args = ["coach", "accept", String(id), "--json"] + (editedText == nil ? [] : ["--stdin"])
        do {
            if let editedText {
                _ = try await runner.run(args: args, stdin: Data(editedText.utf8))
            } else {
                _ = try await runner.run(args: args)
            }
            reloadAll()
        } catch {
            decisionFailed(id, error)
        }
    }

    func decline(_ id: Int64) async {
        guard pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        do {
            _ = try await runner.run(args: ["coach", "decline", String(id), "--json"])
            reloadAll()
        } catch {
            decisionFailed(id, error)
        }
    }

    /// Returns the `diff` when the destination changed since the accept (the
    /// owner may then force it); nil otherwise.
    func rollback(_ id: Int64, force: Bool) async -> String? {
        guard pending.insert(id).inserted else { return nil }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        let args = ["coach", "rollback", String(id), "--json"] + (force ? ["--force"] : [])
        do {
            _ = try await runner.run(args: args)
            reloadAll()
            return nil
        } catch {
            if let failure = Self.failure(error), failure.code == "changed_since" {
                return failure.diff ?? ""
            }
            decisionFailed(id, error)
            return nil
        }
    }

    func runNow() async {
        guard !running else { return }
        running = true
        runLine = nil
        let started = epoch
        // Unstructured on purpose: awaiting it does not tie it to this caller.
        let call = Task { [runner] () -> Result<Data, Error> in
            do {
                return .success(try await runner.run(args: ["coach", "run", "--json"], timeout: Self.runTimeout))
            } catch {
                return .failure(error)
            }
        }
        let result = await call.value
        running = false
        guard started == epoch else { return }
        switch result {
        case let .success(data):
            if let line = Self.judgeErrorLine(data) { runLine = line }
            reloadAll()
        case let .failure(error):
            if Self.failure(error)?.code == "busy" {
                runLine = "The coach is already running — the section updates when it finishes"
            } else {
                runLine = "The coach run failed: \(Self.message(error))"
            }
        }
    }

    // MARK: - Reads

    private func tick() {
        guard isTabOnScreen() else { return }
        for workbench in shown.keys { request(.status(workbench: workbench)) }
        request(.proposals)
    }

    private func reloadAll() {
        for workbench in shown.keys { request(.status(workbench: workbench)) }
        request(.proposals)
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
        case let .status(workbench):
            guard let period = shown[workbench] else { return }
            let args = ["coach", "status", "--workbench", String(workbench), "--days", String(period.rawValue), "--json"]
            do {
                let value = try JSONDecoder().decode(CoachStatus.self, from: try await runner.run(args: args))
                // A reply for a period the pane has since left is dropped.
                guard !Task.isCancelled, shown[workbench] == period else { return }
                status[workbench] = SessionReportCenter.Snapshot(value: value)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), shown[workbench] == period else { return }
                status[workbench, default: SessionReportCenter.Snapshot()].error = Self.message(error)
            }
        case .proposals:
            do {
                let data = try await runner.run(args: ["coach", "proposals", "--status", "all", "--json"])
                let list = try JSONDecoder().decode(CoachProposalList.self, from: data)
                guard !Task.isCancelled else { return }
                proposals = SessionReportCenter.Snapshot(value: list.proposals)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                var current = proposals ?? SessionReportCenter.Snapshot()
                current.error = Self.message(error)
                proposals = current
            }
        }
    }

    // MARK: - Errors

    private func decisionFailed(_ id: Int64, _ error: Error) {
        if let code = Self.failure(error)?.code, code == "stale" || code == "state_changed" {
            cardErrors[id] = "The text changed since — this proposal is closed"
            reloadAll()
        } else {
            cardErrors[id] = Self.message(error)
        }
    }

    private static func failure(_ error: Error) -> CoachFailure? {
        guard case let CLIRunnerError.nonZeroExit(_, stderr) = error else { return nil }
        return CoachFailure.parse(stderr: stderr)
    }

    private static func message(_ error: Error) -> String {
        if let failure = failure(error) { return failure.error }
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return line ?? (code == -1 ? "timed out" : "exit code \(code)")
        }
        return SessionReportCenter.errorLine(error)
    }

    private static func judgeErrorLine(_ data: Data) -> String? {
        struct Out: Decodable { let judge_error: String? }
        guard let text = (try? JSONDecoder().decode(Out.self, from: data))?.judge_error, !text.isEmpty else { return nil }
        return "Verdicts could not be updated: \(text)"
    }
}
