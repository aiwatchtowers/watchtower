import Foundation
import Observation
import WatchtowerCore

/// The agent coach (#1120), run through `watchtower coach …`: a workbench's
/// metrics (`status --workbench N --days D [--agent A]`, the pane's agent
/// filter) while its Analytics pane is
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
    /// The workbench repository file each Accept wrote (`written_path`,
    /// `written_branch`): the folded line and the rollback line name it.
    private(set) var written: [Int64: CoachWrittenFile] = [:]
    /// Proposals with an owner verb in flight: a second press on the same
    /// card does nothing and the card disables its buttons meanwhile.
    private(set) var pending: Set<Int64> = []
    /// Proposal id → the session `coach accept --session` could not link
    /// (spec failure paths): the row offers Open Session / Retry Link and no
    /// Accept, so no second session starts. Persisted (`linkFailedKey`):
    /// it survives navigation and an app restart. An entry is dropped once
    /// the proposal is no longer open or its session row is gone.
    private(set) var linkFailed: [Int64: Int64] = [:]
    /// Session flows between the press and their `coach accept --session`.
    private(set) var sessionStarts: Set<Int64> = []
    /// The session each Accept / Start Again started, and when: the row
    /// stays "starting" until it is live (`starting(live:now:)`).
    private(set) var launched: [Int64: Launch] = [:]

    struct Launch: Equatable {
        let session: Int64
        let at: Date
    }

    nonisolated static let linkFailedKey = "coach.linkFailed"
    /// A started session that never goes live stops counting as starting
    /// after this, so a crash at launch ends on the session's own state.
    nonisolated static let launchGrace: TimeInterval = 60
    nonisolated static let sessionNotStarted = "The session did not start — the proposal is still open"

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

    @ObservationIgnored private let defaults: UserDefaults

    init(runner: any CLIRunnerProtocol, interval: Duration = CoachCenter.interval, defaults: UserDefaults = .standard) {
        self.runner = runner
        self.interval = interval
        self.defaults = defaults
        linkFailed = Self.readLinks(defaults)
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
    /// owner may then force it); nil otherwise. A forced rollback the CLI
    /// still refuses (a created CLAUDE.md/AGENTS.md edited since is never
    /// deleted, spec §4.3a) shows the CLI's line on the card.
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
            if !force, let failure = Self.failure(error), failure.code == "changed_since" {
                return failure.diff ?? ""
            }
            decisionFailed(id, error)
            return nil
        }
    }

    // MARK: - Session destinations (context actions, spec C6)

    /// The proposals whose session is being started: from the press until
    /// the started session is in `live` (`ContextActionsPresentation.rows`
    /// wants them in `starting` until then), or `launchGrace` passed.
    func starting(live: Set<Int64>, now: Date = Date()) -> Set<Int64> {
        let waiting = launched.filter { !live.contains($0.value.session) && now.timeIntervalSince($0.value.at) < Self.launchGrace }
        return sessionStarts.union(waiting.keys)
    }

    /// Accept of a repository or memory proposal: `coach brief`, then
    /// `start(title, prompt)` (the Desktop starts the workbench session),
    /// then `coach accept <id> --session <sid>`. A start that returns nil
    /// leaves the proposal open with the error on its row. A link that fails
    /// after the session started is tried once more; `state_changed` means
    /// another surface accepted it (quiet), anything else records
    /// `linkFailed`. `pending` holds the id throughout, so a second press is
    /// ignored; an id already linked or launched never starts a second one.
    func acceptThroughSession(_ id: Int64, start: (String, String) async -> Int64?) async {
        guard linkFailed[id] == nil, launched[id] == nil else { return }
        await throughSession(id, revert: false, start: start) { session in
            await self.link(id, session: session, restart: false)
        }
    }

    /// **Start Again** on an accepted row whose session ended with nothing:
    /// a new session, recorded with `coach accept --session --restart`.
    func restartThroughSession(_ id: Int64, start: (String, String) async -> Int64?) async {
        await throughSession(id, revert: false, start: start) { session in
            await self.link(id, session: session, restart: true)
        }
    }

    /// **Revert…** of a merged repository change: a session started with
    /// `coach brief <id> --revert`. Nothing is recorded: its PR is the record.
    func revertThroughSession(_ id: Int64, start: (String, String) async -> Int64?) async {
        await throughSession(id, revert: true, start: start) { _ in }
    }

    /// **Retry Link**: the same `coach accept --session` with the session
    /// that could not be linked.
    func retryLink(_ id: Int64) async {
        guard let session = linkFailed[id], pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        do {
            _ = try await runner.run(args: ["coach", "accept", String(id), "--session", String(session), "--json"])
            setLink(id, nil)
        } catch where Self.failure(error)?.code == "state_changed" {
            setLink(id, nil)
        } catch {
            cardErrors[id] = Self.message(error)
            return
        }
        await reloadProposalsNow()
    }

    /// **Dismiss**: closes an accepted session row that ended with nothing.
    func dismiss(_ id: Int64) async {
        await verb(id, ["coach", "dismiss", String(id), "--json"])
    }

    /// **Turn Off Again**: a setting turned back on outside Watchtower.
    func reapply(_ id: Int64) async {
        await verb(id, ["coach", "reapply", String(id), "--json"])
    }

    /// The pane found `session`'s row gone: a link entry naming it goes.
    func forgetLink(_ id: Int64, session: Int64) {
        if linkFailed[id] == session { setLink(id, nil) }
    }

    private func verb(_ id: Int64, _ args: [String]) async {
        guard pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        do {
            _ = try await runner.run(args: args)
            reloadAll()
        } catch {
            decisionFailed(id, error)
        }
    }

    private func throughSession(
        _ id: Int64, revert: Bool, start: (String, String) async -> Int64?, record: (Int64) async -> Void
    ) async {
        guard pending.insert(id).inserted else { return }
        sessionStarts.insert(id)
        defer {
            sessionStarts.remove(id)
            pending.remove(id)
        }
        cardErrors[id] = nil
        let brief: CoachBrief
        do {
            let args = ["coach", "brief", String(id)] + (revert ? ["--revert"] : []) + ["--json"]
            brief = try JSONDecoder().decode(CoachBrief.self, from: try await runner.run(args: args))
        } catch {
            decisionFailed(id, error)
            return
        }
        guard let session = await start(brief.title, brief.prompt) else {
            cardErrors[id] = Self.sessionNotStarted
            return
        }
        if !revert { launched[id] = Launch(session: session, at: Date()) }
        await record(session)
        // The press is released once the list shows the change, so the
        // row never offers its old buttons in between.
        await reloadProposalsNow()
        for workbench in shown.keys { request(.status(workbench: workbench)) }
    }

    /// `coach accept --session` once more after a failure; `state_changed`
    /// on either try is another surface's Accept (quiet).
    private func link(_ id: Int64, session: Int64, restart: Bool) async {
        let args = ["coach", "accept", String(id), "--session", String(session)] + (restart ? ["--restart"] : []) + ["--json"]
        var last: Error?
        for _ in 0..<2 {
            do {
                _ = try await runner.run(args: args)
                return
            } catch where Self.failure(error)?.code == "state_changed" {
                return
            } catch {
                last = error
            }
        }
        guard let last else { return }
        if restart {
            // An accepted row: its card keeps Start Again, with the error.
            cardErrors[id] = "\(ContextActionsPresentation.Copy.linkFailed): \(Self.message(last))"
        } else {
            setLink(id, session)
        }
    }

    private func setLink(_ id: Int64, _ session: Int64?) {
        linkFailed[id] = session
        defaults.set(Dictionary(uniqueKeysWithValues: linkFailed.map { (String($0.key), NSNumber(value: $0.value)) }),
                     forKey: Self.linkFailedKey)
    }

    private static func readLinks(_ defaults: UserDefaults) -> [Int64: Int64] {
        var links: [Int64: Int64] = [:]
        for (key, value) in defaults.dictionary(forKey: linkFailedKey) ?? [:] {
            if let id = Int64(key), let session = (value as? NSNumber)?.int64Value { links[id] = session }
        }
        return links
    }

    /// Drops the link entries whose proposal is no longer open.
    private func pruneLinks(_ proposals: [CoachProposal]) {
        let open = Set(proposals.filter { $0.status == "open" }.map(\.id))
        for id in linkFailed.keys where !open.contains(id) { setLink(id, nil) }
    }

    /// Reads the proposal list and waits for it, a read already in flight
    /// and its queued rerun included.
    private func reloadProposalsNow() async {
        request(.proposals)
        while let task = inFlight[.proposals]?.task { await task.value }
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
                proposals = SessionReportCenter.Snapshot(value: list.proposals)
                pruneLinks(list.proposals)
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
        switch Self.failure(error)?.code {
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

/// `coach brief <id> [--revert] --json`: the session's title and prompt.
struct CoachBrief: Decodable {
    let title: String
    let prompt: String
}
