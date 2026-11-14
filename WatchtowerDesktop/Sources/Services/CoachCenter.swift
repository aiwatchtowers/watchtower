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
    /// The `linkFailed` entries a Start Again (`--restart`) left: an
    /// accepted row whose new session is unlinked. Retry Link sends
    /// `--restart`; the entry goes once the row names that session.
    /// Persisted (`restartLinksKey`).
    private(set) var restartLinks: Set<Int64> = []
    /// Proposal id → the revert session Revert… started (`revertSessionsKey`):
    /// the row offers Open Session instead of a second Revert…. Dropped when
    /// the proposal is no longer accepted or the session row is gone.
    private(set) var revertSessions: [Int64: Int64] = [:]
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
    nonisolated static let restartLinksKey = "coach.linkFailedRestart"
    nonisolated static let revertSessionsKey = "coach.revertSessions"
    nonisolated static let alreadyStarted = "A session already started for this proposal — the list is being read again"
    /// A started session that never goes live stops counting as starting
    /// after this, so a crash at launch ends on the session's own state.
    nonisolated static let launchGrace: TimeInterval = 60
    nonisolated static let sessionNotStarted = "The session did not start — the proposal is still open"
    nonisolated static let reapplyStale = "The setting changed again — nothing was turned off"

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
        linkFailed = Self.readMap(defaults, Self.linkFailedKey)
        revertSessions = Self.readMap(defaults, Self.revertSessionsKey)
        restartLinks = Set((defaults.array(forKey: Self.restartLinksKey) as? [NSNumber] ?? []).map(\.int64Value))
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
        guard linkFailed[id] == nil else { return }
        // Accepted already, but the list still says open (its read failed).
        guard launched[id] == nil else {
            cardErrors[id] = Self.alreadyStarted
            refreshProposals()
            return
        }
        await throughSession(id, revert: false, start: start) { session in
            await self.link(id, session: session, restart: false)
        }
    }

    /// **Start Again** on an accepted row whose session ended with nothing:
    /// a new session, recorded with `coach accept --session --restart`.
    func restartThroughSession(_ id: Int64, start: (String, String) async -> Int64?) async {
        guard linkFailed[id] == nil else { return }
        await throughSession(id, revert: false, start: start) { session in
            await self.link(id, session: session, restart: true)
        }
    }

    /// **Revert…** of a merged repository change: a session started with
    /// `coach brief <id> --revert`. Nothing is recorded: its PR is the record.
    func revertThroughSession(_ id: Int64, start: (String, String) async -> Int64?) async {
        guard revertSessions[id] == nil else { return }
        await throughSession(id, revert: true, start: start) { session in
            self.setRevert(id, session)
        }
    }

    /// Drops the revert entry if it still names `session`: the pane found
    /// that session's row gone, or Revert… is pressed again after it ended
    /// (`.revertEnded`).
    func forgetRevert(_ id: Int64, session: Int64) {
        if revertSessions[id] == session { setRevert(id, nil) }
    }

    /// A session start is in flight or waits to go live: the rows need a
    /// redraw when `launchGrace` passes.
    var hasLaunches: Bool { !sessionStarts.isEmpty || !launched.isEmpty }

    /// **Retry Link**: the same `coach accept --session` with the session
    /// that could not be linked.
    func retryLink(_ id: Int64) async {
        guard let session = linkFailed[id], pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        let restart = restartLinks.contains(id) ? ["--restart"] : []
        do {
            _ = try await runner.run(args: ["coach", "accept", String(id), "--session", String(session)] + restart + ["--json"])
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

    /// **Turn Off Again**: a setting turned back on outside Watchtower. A
    /// `stale` answer means the setting no longer reads on, or changed
    /// meanwhile: the row is still accepted, so it gets its own line, never
    /// the closed-proposal one.
    func reapply(_ id: Int64) async {
        guard pending.insert(id).inserted else { return }
        defer { pending.remove(id) }
        cardErrors[id] = nil
        do {
            _ = try await runner.run(args: ["coach", "reapply", String(id), "--json"])
            reloadAll()
        } catch where Self.failure(error)?.code == "stale" {
            cardErrors[id] = Self.reapplyStale
            reloadAll()
        } catch where Self.failure(error)?.code == "state_changed" {
            reloadAll() // turned off again or rolled back elsewhere: the list shows it
        } catch {
            decisionFailed(id, error)
        }
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
        // A revert session too: its row stays "reverting" until it is live.
        launched[id] = Launch(session: session, at: Date())
        await record(session)
        // The press is released once the list shows the change, so the
        // row never offers its old buttons in between.
        await reloadProposalsNow()
        for workbench in shown.keys { request(.status(workbench: workbench)) }
    }

    /// `coach accept --session` once more after a failure. `state_changed`
    /// on an Accept is another surface's Accept (quiet); on a `--restart` it
    /// means the row was not moved to this session, so the new session
    /// would run unlinked: it is a link failure like any other (the list
    /// read that follows drops the entry if the row does name the session).
    /// The last error stays on the card.
    private func link(_ id: Int64, session: Int64, restart: Bool) async {
        let args = ["coach", "accept", String(id), "--session", String(session)] + (restart ? ["--restart"] : []) + ["--json"]
        var last: Error?
        for _ in 0..<2 {
            do {
                _ = try await runner.run(args: args)
                return
            } catch where Self.failure(error)?.code == "state_changed" {
                guard restart else { return }
                last = error
                break
            } catch {
                last = error
            }
        }
        // Retry Link and Open Session from now on, on an open row and on an
        // accepted one alike: never a second session.
        setLink(id, session, restart: restart)
        cardErrors[id] = last.map(Self.message)
    }

    private func setLink(_ id: Int64, _ session: Int64?, restart: Bool = false) {
        linkFailed[id] = session
        if session != nil, restart { restartLinks.insert(id) } else { restartLinks.remove(id) }
        Self.writeMap(linkFailed, defaults, Self.linkFailedKey)
        defaults.set(restartLinks.sorted().map { NSNumber(value: $0) }, forKey: Self.restartLinksKey)
    }

    private func setRevert(_ id: Int64, _ session: Int64?) {
        revertSessions[id] = session
        Self.writeMap(revertSessions, defaults, Self.revertSessionsKey)
    }

    private static func writeMap(_ map: [Int64: Int64], _ defaults: UserDefaults, _ key: String) {
        defaults.set(Dictionary(uniqueKeysWithValues: map.map { (String($0.key), NSNumber(value: $0.value)) }), forKey: key)
    }

    private static func readMap(_ defaults: UserDefaults, _ key: String) -> [Int64: Int64] {
        var map: [Int64: Int64] = [:]
        for (key, value) in defaults.dictionary(forKey: key) ?? [:] {
            if let id = Int64(key), let session = (value as? NSNumber)?.int64Value { map[id] = session }
        }
        return map
    }

    /// After a list read: an Accept's link entry goes once the proposal is
    /// no longer open; a Start Again's once the row is no longer accepted or
    /// names that session; a revert entry once the row is no longer
    /// accepted; a launch once its row is no longer open and the grace passed.
    private func prune(_ proposals: [CoachProposal], now: Date = Date()) {
        let byID = Dictionary(proposals.map { ($0.id, $0) }) { a, _ in a }
        for (id, session) in linkFailed {
            let p = byID[id]
            let keep = restartLinks.contains(id)
                ? p?.status == "accepted" && p?.sessionID != session
                : p?.status == "open"
            if !keep {
                setLink(id, nil)
                cardErrors[id] = nil // the link line's reason goes with it
            }
        }
        for id in revertSessions.keys where byID[id]?.status != "accepted" { setRevert(id, nil) }
        for (id, launch) in launched where byID[id]?.status != "open" && now.timeIntervalSince(launch.at) >= Self.launchGrace {
            launched[id] = nil
        }
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
                prune(list.proposals)
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
