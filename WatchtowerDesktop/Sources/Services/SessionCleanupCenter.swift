import Foundation
import Observation
import WatchtowerCore

/// Runs a `watchtower` command with the child's whole environment given —
/// what `SessionCleanupCenter` needs to keep `WATCHTOWER_TERMINAL_SESSION_ID`
/// away from its cleanup calls.
protocol SessionCleanupRunning {
    func runCleanupCommand(args: [String], environment: [String: String]) async throws -> Data
}

extension ProcessCLIRunner: SessionCleanupRunning {
    func runCleanupCommand(args: [String], environment: [String: String]) async throws -> Data {
        try await run(args: args, environment: environment)
    }
}

/// What a cleanup state is kept for: one session (the Delete dialog, the
/// Clean Up… sheet) or one workbench (the sweep).
enum SessionCleanupScope: Hashable {
    case session(Int64)
    case workbench(Int64)
}

/// Where a scope's cleanup is (spec 2026-10-12-session-cleanup §12).
enum SessionCleanupPhase: Equatable {
    case idle
    case planning
    case ready(SessionCleanupPlan)
    case applying
    /// The apply's result: what was removed, kept and failed.
    case done(SessionCleanupPlan)
    case failed(String)
}

/// Session cleanup from the Desktop (board #535, spec
/// 2026-10-12-session-cleanup §12): runs `watchtower workbench cleanup
/// --json` — a plan, or an apply of exactly the keys the owner saw — and
/// keeps each scope's phase. Held by the AppState-owned
/// `WorkbenchesViewModel`, so a plan or an apply in flight survives
/// navigating away. It never runs git, `lsof` or
/// `lsregister` and never writes the database: Go is the only writer.
///
/// Every call runs without `WATCHTOWER_TERMINAL_SESSION_ID` in the child's
/// environment (spec §4): inside a terminal session the CLI confines the
/// caller to that one session, and an app started from a workbench terminal
/// (a dev build) would hand the variable on to every child.
@MainActor
@Observable
final class SessionCleanupCenter {
    nonisolated static let terminalSessionVariable = "WATCHTOWER_TERMINAL_SESSION_ID"

    private(set) var phases: [SessionCleanupScope: SessionCleanupPhase] = [:]

    /// The Desktop's live terminals, passed as `--live-session` (Go keeps a
    /// worktree a live session works in). AppState wires it to
    /// `TerminalCenter.liveIDs`.
    @ObservationIgnored var liveSessionIDs: () -> Set<Int64> = { [] }
    /// The environment the cleanup child starts from, before the terminal
    /// session variable is dropped. A seam for tests.
    @ObservationIgnored var baseEnvironment: () async -> [String: String] = { await Constants.resolvedEnvironmentAsync() }

    /// nil: the watchtower binary was not found; every run fails with that.
    @ObservationIgnored private let runner: (any SessionCleanupRunning)?
    /// Per scope, the newest run started: an older run's answer is dropped.
    @ObservationIgnored private var runSerials: [SessionCleanupScope: Int] = [:]
    /// Per scope, the plan last started by `startPlan`: owned here, never by
    /// a view, so a sheet torn down when the owner leaves the page neither
    /// stops the CLI nor fails the plan.
    @ObservationIgnored private var planRuns: [SessionCleanupScope: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Per scope, the time limit its running plan was stopped at; that
    /// plan's cancellation then reads as a failure, not as nothing to show.
    @ObservationIgnored private var stoppedAtLimit: [SessionCleanupScope: Duration] = [:]
    /// Per scope, when its ready plan landed.
    @ObservationIgnored private var readyAt: [SessionCleanupScope: Date] = [:]
    /// A seam for tests.
    @ObservationIgnored var now: () -> Date = { Date() }

    init(runner: (any SessionCleanupRunning)?) {
        self.runner = runner
    }

    /// The Workbench page's center: the app's process runner (a runner of
    /// another kind cannot take an environment, so runs then fail as
    /// "binary not found") and `terminals`' live sessions.
    static func forWorkbenches(runner: (any CLIRunnerProtocol)?, terminals: TerminalCenter) -> SessionCleanupCenter {
        let center = SessionCleanupCenter(runner: runner as? ProcessCLIRunner)
        center.liveSessionIDs = { [weak terminals] in terminals?.liveIDs ?? [] }
        return center
    }

    func cleanupPhase(for scope: SessionCleanupScope) -> SessionCleanupPhase {
        phases[scope] ?? .idle
    }

    /// Starts planning session `sessionID`'s cleanup in a task the center
    /// owns (see `planCleanup`) and returns it. A caller awaiting its value
    /// may be cancelled — a sheet's `.task` when the page is left — without
    /// cancelling the plan: it runs on and its phase stays readable. A
    /// plan this started earlier for the scope and still running is
    /// stopped (its answer would be dropped anyway); a finished one is not
    /// kept.
    @discardableResult
    func startPlan(sessionID: Int64, workbenchID: Int64, closingSession: Bool = false) -> Task<Void, Never> {
        startOwnedPlan(.session(sessionID)) { center in
            await center.planCleanup(sessionID: sessionID, workbenchID: workbenchID, closingSession: closingSession)
        }
    }

    /// Starts the sweep plan of workbench `workbenchID` (spec §9) in a task
    /// the center owns, as `startPlan` does for a session. With `timeLimit`
    /// a plan still running after it is stopped and fails (a read stalled
    /// on a dead mount never keeps the sheet waiting, board #704).
    @discardableResult
    func startSweepPlan(workbenchID: Int64, timeLimit: Duration? = nil) -> Task<Void, Never> {
        startOwnedPlan(.workbench(workbenchID), timeLimit: timeLimit) { center in
            await center.planSweep(workbenchID: workbenchID)
        }
    }

    /// The plan `startPlan`/`startSweepPlan` still runs for the scope.
    func runningPlan(for scope: SessionCleanupScope) -> Task<Void, Never>? {
        planRuns[scope]?.task
    }

    /// How long ago the scope's ready plan landed; nil when it has none.
    func readyPlanAge(for scope: SessionCleanupScope) -> TimeInterval? {
        guard case .ready = cleanupPhase(for: scope), let at = readyAt[scope] else { return nil }
        return now().timeIntervalSince(at)
    }

    private func startOwnedPlan(
        _ scope: SessionCleanupScope, timeLimit: Duration? = nil,
        _ body: @escaping @MainActor (SessionCleanupCenter) async -> Void
    ) -> Task<Void, Never> {
        let token = UUID()
        let run = Task<Void, Never> { [weak self] in
            guard let self else { return }
            let watchdog = timeLimit.map { limit in
                Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled, let self, let run = planRuns[scope], run.token == token else { return }
                    stoppedAtLimit[scope] = limit
                    run.task.cancel()
                }
            }
            await body(self)
            watchdog?.cancel()
            if planRuns[scope]?.token == token { planRuns[scope] = nil }
        }
        planRuns.updateValue((token, run), forKey: scope)?.task.cancel()
        return run
    }

    /// Plans session `sessionID`'s cleanup (writes nothing). `closingSession`:
    /// the plan is for the Delete dialog, which closes the session's
    /// terminal before it applies — the session's own id is then not passed
    /// as live, or Go would keep its worktree for "a session works in it".
    /// Ignored while the scope applies. Returns the run's serial when its
    /// outcome became the scope's phase (compare `latestRun(for:)` to tell
    /// it from a later run's); nil when it was ignored, superseded or
    /// cancelled.
    @discardableResult
    func planCleanup(sessionID: Int64, workbenchID: Int64, closingSession: Bool = false) async -> Int? {
        var live = liveSessionIDs()
        if closingSession { live.remove(sessionID) }
        let args = Self.cleanupArguments(sessionID: sessionID, workbenchID: workbenchID, live: live)
        return await runPlan(.session(sessionID), args: args)
    }

    /// The serial of the scope's newest run (a plan, an apply, or a
    /// `forgetCleanup`): a run a caller started is still the scope's while
    /// this equals the serial it got.
    func latestRun(for scope: SessionCleanupScope) -> Int {
        runSerials[scope, default: 0]
    }

    /// Plans the sweep of workbench `workbenchID` (writes nothing): every
    /// worktree and branch of its repository with an owner hint, every live
    /// terminal passed (Go keeps what a live session works in). Ignored
    /// while the sweep applies.
    func planSweep(workbenchID: Int64) async {
        await runPlan(.workbench(workbenchID), args: Self.sweepArguments(workbenchID: workbenchID, live: liveSessionIDs()))
    }

    /// The run's serial once its outcome is the scope's phase; nil otherwise.
    @discardableResult
    private func runPlan(_ scope: SessionCleanupScope, args: [String]) async -> Int? {
        guard cleanupPhase(for: scope) != .applying else { return nil }
        let serial = beginRun(scope, phase: .planning)
        let outcome = await runCleanup(args)
        guard runSerials[scope] == serial else { return nil }
        // A cancelled caller is not a failed plan: nothing to show — unless
        // its time limit stopped it.
        guard !Task.isCancelled else {
            if let limit = stoppedAtLimit.removeValue(forKey: scope) {
                phases[scope] = .failed(Self.overLimitText(limit))
                return serial
            }
            phases[scope] = nil
            return nil
        }
        switch outcome {
        case let .success(plan):
            phases[scope] = .ready(plan)
            readyAt[scope] = now()
        case let .failure(message): phases[scope] = .failed(message)
        }
        return serial
    }

    /// Applies exactly `items` (the planned `remove` keys the owner saw) to
    /// session `sessionID`. Go re-plans and acts only on items eligible at
    /// that moment and among `items`. With no item nothing runs — an apply
    /// without `--item` would remove everything eligible — and that counts
    /// as success. True when the CLI ran and no item reported an error
    /// (`failureText(for:)` says what failed otherwise); a kept item is not
    /// a failure.
    func applyCleanup(sessionID: Int64, workbenchID: Int64, items: [String]) async -> Bool {
        guard !items.isEmpty else { return true }
        let args = Self.cleanupArguments(
            sessionID: sessionID, workbenchID: workbenchID, live: liveSessionIDs(), applying: items
        )
        return await runApply(.session(sessionID), args: args)
    }

    /// Applies exactly `items` — the sweep keys the owner ticked — to
    /// workbench `workbenchID`, as `applyCleanup` does for a session. With
    /// no item nothing runs (Go refuses a sweep apply without `--item`).
    func applySweep(workbenchID: Int64, items: [String]) async -> Bool {
        guard !items.isEmpty else { return true }
        let args = Self.sweepArguments(workbenchID: workbenchID, live: liveSessionIDs(), applying: items)
        return await runApply(.workbench(workbenchID), args: args)
    }

    private func runApply(_ scope: SessionCleanupScope, args: [String]) async -> Bool {
        let serial = beginRun(scope, phase: .applying)
        let outcome = await runCleanup(args)
        // A plan never supersedes an apply (it does not start while one
        // runs); only a second apply would.
        if runSerials[scope] == serial {
            switch outcome {
            case let .success(result): phases[scope] = .done(result)
            case let .failure(message): phases[scope] = .failed(message)
            }
        }
        if case let .success(result) = outcome { return Self.itemFailures(result) == nil }
        return false
    }

    /// Why the scope's last run failed: the CLI's error, or the items an
    /// apply could not remove; nil when nothing failed.
    func failureText(for scope: SessionCleanupScope) -> String? {
        switch cleanupPhase(for: scope) {
        case let .failed(message): message
        case let .done(result): Self.itemFailures(result)
        default: nil
        }
    }

    /// Forgets the scope's phase (a dialog closed, a delete finished) and
    /// stops a plan `startPlan` still runs for it. An apply in flight is
    /// kept.
    func forgetCleanup(_ scope: SessionCleanupScope) {
        guard cleanupPhase(for: scope) != .applying else { return }
        runSerials[scope, default: 0] += 1
        phases[scope] = nil
        planRuns.removeValue(forKey: scope)?.task.cancel()
    }

    // MARK: Running

    private func beginRun(_ scope: SessionCleanupScope, phase: SessionCleanupPhase) -> Int {
        let serial = runSerials[scope, default: 0] + 1
        runSerials[scope] = serial
        stoppedAtLimit[scope] = nil
        phases[scope] = phase
        return serial
    }

    private enum Outcome {
        case success(SessionCleanupPlan)
        case failure(String)
    }

    private func runCleanup(_ args: [String]) async -> Outcome {
        guard let runner else { return .failure(CLIRunnerError.binaryNotFound.localizedDescription) }
        let environment = Self.cleanupEnvironment(await baseEnvironment())
        do {
            let data = try await runner.runCleanupCommand(args: args, environment: environment)
            return .success(try JSONDecoder().decode(SessionCleanupPlan.self, from: data))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// The failure of a plan its time limit stopped.
    nonisolated static func overLimitText(_ limit: Duration) -> String {
        let minutes = max(1, Int(limit.components.seconds / 60))
        return "Checking took longer than \(minutes) min and was stopped (a worktree may be unreadable)."
    }

    /// `base` without `WATCHTOWER_TERMINAL_SESSION_ID` (spec §4).
    nonisolated static func cleanupEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base
        environment[terminalSessionVariable] = nil
        return environment
    }

    /// `workbench cleanup --session S --workbench W [--live-session L]…
    /// [--apply --item K…] --json`. Values travel as `--flag=value`, so a
    /// key is never read as a flag.
    nonisolated static func cleanupArguments(
        sessionID: Int64, workbenchID: Int64, live: Set<Int64>, applying items: [String]? = nil
    ) -> [String] {
        var args = ["workbench", "cleanup", "--session=\(sessionID)", "--workbench=\(workbenchID)"]
        args += live.sorted().map { "--live-session=\($0)" }
        if let items { args += ["--apply"] + items.map { "--item=\($0)" } }
        return args + ["--json"]
    }

    /// `workbench cleanup --workbench W --sweep [--live-session L]…
    /// [--apply --item K…] --json` (spec §4: a sweep names no session).
    nonisolated static func sweepArguments(
        workbenchID: Int64, live: Set<Int64>, applying items: [String]? = nil
    ) -> [String] {
        var args = ["workbench", "cleanup", "--workbench=\(workbenchID)", "--sweep"]
        args += live.sorted().map { "--live-session=\($0)" }
        if let items { args += ["--apply"] + items.map { "--item=\($0)" } }
        return args + ["--json"]
    }

    /// "x: git refused …; feat/x: …" over the items whose removal failed;
    /// nil when none did.
    nonisolated static func itemFailures(_ result: SessionCleanupPlan) -> String? {
        let failed = result.items.filter { !$0.error.isEmpty }
        guard !failed.isEmpty else { return nil }
        return failed.map { "\($0.name.isEmpty ? $0.key : $0.name): \($0.error)" }.joined(separator: "; ")
    }
}
