import Foundation
import Observation
import WatchtowerCore

/// The agent coach (#1120), run through `watchtower coach …`: a workbench's
/// metrics (`status --workbench N --days D [--agent A]`, the pane's agent
/// filter) while its Analytics pane is
/// shown, the proposals (`proposals --status all`), and the owner's verbs
/// Accept / Decline / Roll back / Run now, and `sync-prs` when Accepted
/// edits or the tuning panel appears (spec 2026-11-19 §4.4).
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
    /// The workbench repository file each Accept wrote (`written_path`,
    /// `written_branch`): the folded line and the rollback line name it.
    private(set) var written: [Int64: CoachWrittenFile] = [:]
    /// Proposals with an owner verb in flight: a second press on the same
    /// card does nothing and the card disables its buttons meanwhile.
    private(set) var pending: Set<Int64> = []
    /// Cards whose last verb GitHub or the network refused (`push_failed`,
    /// `pr_failed`, `timeout`, `pr_unreadable`): Retry runs it again.
    private(set) var retries: [Int64: Retry] = [:]
    /// `coach sync-prs` is running.
    private(set) var syncing = false
    /// Over Accepted edits when the last `coach sync-prs` could not read
    /// some pull requests or failed; nil once a sync read them all.
    private(set) var syncLine: String?

    /// The verb a card's Retry runs again.
    enum Retry: Equatable {
        case accept(editedText: String?)
        case rollback
    }

    @ObservationIgnored var isTabOnScreen: () -> Bool = { false }

    private enum RunKey: Hashable {
        case status(workbench: Int64)
        case proposals
    }

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var shown: [Int64: AgentAnalyticsCenter.Query] = [:]
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

    func show(workbench: Int64, period: AgentAnalyticsCenter.Period, agent: AgentAnalyticsCenter.Agent = .all) {
        let query = AgentAnalyticsCenter.Query(period: period, agent: agent)
        let changed = shown[workbench] != query
        shown[workbench] = query
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
        retries[id] = nil
        let args = ["coach", "accept", String(id), "--json"] + (editedText == nil ? [] : ["--stdin"])
        do {
            let data = if let editedText {
                try await runner.run(args: args, stdin: Data(editedText.utf8))
            } else {
                try await runner.run(args: args)
            }
            if let file = CoachWrittenFile.parse(acceptResult: data) { written[id] = file }
            reloadAll()
        } catch {
            decisionFailed(id, error, retry: .accept(editedText: editedText))
        }
    }

    func decline(_ id: Int64) async {
        guard pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        retries[id] = nil
        do {
            _ = try await runner.run(args: ["coach", "decline", String(id), "--json"])
            reloadAll()
        } catch {
            decisionFailed(id, error)
        }
    }

    /// Returns the `diff` when the destination changed since the accept (the
    /// owner may then force it); nil otherwise. A forced rollback the CLI
    /// still refuses (a created CLAUDE.md/AGENTS.md edited since is never
    /// deleted, spec §4.3a) shows the CLI's line on the card.
    func rollback(_ id: Int64, force: Bool) async -> String? {
        guard pending.insert(id).inserted else { return nil }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        retries[id] = nil
        let args = ["coach", "rollback", String(id), "--json"] + (force ? ["--force"] : [])
        do {
            _ = try await runner.run(args: args)
            reloadAll()
            return nil
        } catch {
            if !force, let failure = Self.failure(error), failure.code == "changed_since" {
                return failure.diff ?? ""
            }
            decisionFailed(id, error, retry: .rollback)
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
                return .success(try await runner.runModel(
                    args: ["coach", "run", "--json"], origin: .owner, timeout: Self.runTimeout, stdin: nil))
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

    /// `coach sync-prs` once: the Accepted edits list or the tuning panel
    /// appeared (spec 2026-11-19 §4.4; never on the tick). A call while one
    /// runs does nothing; when rows changed the pane reloads. Like `runNow`,
    /// `stop()` only skips applying the result.
    func syncPRs() {
        guard !syncing else { return }
        syncing = true
        let started = epoch
        Task { [weak self, runner] in
            let result: Result<Data, Error>
            do {
                result = .success(try await runner.run(args: ["coach", "sync-prs", "--json"]))
            } catch {
                result = .failure(error)
            }
            self?.syncFinished(result, epoch: started)
        }
    }

    private func syncFinished(_ result: Result<Data, Error>, epoch started: Int) {
        syncing = false
        guard started == epoch else { return }
        do {
            let out = try JSONDecoder().decode(CoachSyncResult.self, from: result.get())
            syncLine = out.syncError.isEmpty ? nil : CoachPRTexts.syncLine(code: out.syncCode)
            if out.changed > 0 { reloadAll() }
        } catch {
            syncLine = CoachPRTexts.syncFailed
        }
    }

    // MARK: - Reads

    /// Reloads the proposal list now (the tuning panel, after the chat
    /// proposed an edit); the one-in-flight-plus-one-queued rule applies.
    func refreshProposals() {
        request(.proposals)
    }

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
            guard let query = shown[workbench] else { return }
            var args = ["coach", "status", "--workbench", String(workbench), "--days", String(query.period.rawValue)]
            if let flag = query.agent.flag { args += ["--agent", flag] }
            args.append("--json")
            do {
                let value = try JSONDecoder().decode(CoachStatus.self, from: try await runner.run(args: args))
                // A reply for a period or filter the pane has since left is dropped.
                guard !Task.isCancelled, shown[workbench] == query else { return }
                status[workbench] = SessionReportCenter.Snapshot(value: value)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), shown[workbench] == query else { return }
                status[workbench, default: SessionReportCenter.Snapshot()].error = Self.message(error)
            }
        case .proposals:
            do {
                let data = try await runner.run(args: ["coach", "proposals", "--status", "all", "--json"])
                let list = try JSONDecoder().decode(CoachProposalList.self, from: data)
                guard !Task.isCancelled else { return }
                // A card whose proposal moved on (a sync rolled it back, a stale one closed) drops
                // the error and the Retry made for its old state.
                let before = Dictionary((proposals?.value ?? []).map { ($0.id, $0.status) }) { first, _ in first }
                for p in list.proposals where before[p.id].map({ $0 != p.status }) == true {
                    cardErrors[p.id] = nil
                    retries[p.id] = nil
                }
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

    private func decisionFailed(_ id: Int64, _ error: Error, retry: Retry? = nil) {
        let failure = Self.failure(error)
        if CoachPRTexts.retryable(failure?.code) { retries[id] = retry }
        switch failure?.code {
        case "stale", "state_changed":
            cardErrors[id] = "The text changed since — this proposal is closed"
            reloadAll()
        case "dirty":
            // The card names its own file; the CLI's line carries the proposal id.
            let path = proposals?.value?.first { $0.id == id }?.repoRelativePath
            cardErrors[id] = path.map { TuningChatTexts.repoDirty(path: $0) } ?? Self.message(error)
        case "not_git":
            cardErrors[id] = TuningChatTexts.repoNotGit
        default:
            // A pull-request refusal names the card's file and PR; the CLI's line carries the proposal id.
            let proposal = proposals?.value?.first { $0.id == id }
            cardErrors[id] = failure.flatMap {
                CoachPRTexts.refusal(code: $0.code ?? "", cliError: $0.error, path: proposal?.repoRelativePath,
                                     prURL: proposal?.prURL ?? "")
            } ?? Self.message(error)
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
