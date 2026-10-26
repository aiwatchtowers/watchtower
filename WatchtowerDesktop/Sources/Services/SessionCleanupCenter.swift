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

/// Starts `watchtower workbench cleanup … --json --stream` and hands its
/// stdout as lines (spec 2026-10-26-worktree-cleanup-screen §6). The
/// production conformer is `ProcessCLIRunner` over `CodeCLIProcess`.
protocol SessionCleanupStreaming {
    func streamCleanup(args: [String], environment: [String: String]) throws -> SessionCleanupStream
}

/// One streamed cleanup child: its stdout lines (ending at EOF), its exit
/// once reaped, and a stop (SIGTERM to its group, idempotent).
struct SessionCleanupStream: Sendable {
    struct Exit: Equatable, Sendable {
        let status: Int32
        /// The failure text as a non-streamed run words it.
        let message: String
    }

    let lines: AsyncStream<String>
    let exit: @Sendable () async -> Exit
    let stop: @Sendable () -> Void
}

extension ProcessCLIRunner: SessionCleanupStreaming {
    func streamCleanup(args: [String], environment: [String: String]) throws -> SessionCleanupStream {
        let process = try CodeCLIProcess.launch(executable: binaryPath, arguments: args, environment: environment)
        let output = process.output
        let lines = AsyncStream<String> { continuation in
            let reader = Task.detached {
                var splitter = NDJSONLineSplitter()
                for await chunk in output {
                    for line in splitter.append(chunk) { continuation.yield(line) }
                }
                if let tail = splitter.finish() { continuation.yield(tail) }
                continuation.finish()
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
        return SessionCleanupStream(
            lines: lines,
            exit: {
                let exit = await process.exitStatus
                let stderr = exit.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = CLIRunnerError.nonZeroExit(code: exit.status, stderr: stderr).localizedDescription
                return SessionCleanupStream.Exit(status: exit.status, message: message)
            },
            stop: { process.terminateGroup() }
        )
    }
}

/// A streamed run's rows so far (spec §7): what `listed`, `checked`,
/// `sized` and the apply's `removing`/`removed` said, until `done.plan`
/// replaces them. `runID` is the scope's run serial it belongs to.
struct SessionCleanupProgress: Equatable {
    var runID: Int
    var items: [SessionCleanupItem] = []
    /// Keys still waiting for their `checked` event.
    var checking: Set<String> = []
    /// Removable worktrees checked and waiting for their size.
    var sizing: Set<String> = []
    /// Keys the running apply is removing now.
    var removing: Set<String> = []
    var stage: CleanupStage = .listing

    /// A plan's event. `checked` of a key `listed` never named (a stale
    /// LaunchServices entry, a sweep's branch) is a new row.
    mutating func absorbPlan(_ event: SessionCleanupEvent, now: Date) {
        switch event {
        case let .listed(listed):
            items = listed
            checking = Set(listed.map(\.key))
            sizing = []
        case let .checked(item):
            upsert(item)
            checking.remove(item.key)
            if item.kind == .worktree, item.action == .remove, !item.bytesKnown { sizing.insert(item.key) }
        case let .sized(key, bytes, known):
            if let index = items.firstIndex(where: { $0.key == key }) {
                items[index].bytes = bytes
                items[index].bytesKnown = known
            }
            sizing.remove(key)
        case let .done(plan):
            items = plan.items
            checking = []
            sizing = []
            stage = .ready(at: now)
            return
        case .removing, .removed:
            return
        }
        stage = planStage
    }

    /// An apply's event: a removed row leaves, a kept or failed one takes
    /// its new state; rows not in `applied` stay as they are. The apply's
    /// own re-plan lines never reset the rows.
    mutating func absorbApply(_ event: SessionCleanupEvent, applied: Set<String>) {
        switch event {
        case let .removing(key):
            removing.insert(key)
        case let .removed(item):
            removing.remove(item.key)
            settle(item)
        case let .done(result):
            for item in result.items where item.done || applied.contains(item.key) { settle(item) }
            removing = []
            stage = .done(result)
        case .listed, .checked, .sized:
            break
        }
    }

    private mutating func settle(_ item: SessionCleanupItem) {
        if item.done {
            items.removeAll { $0.key == item.key }
        } else {
            upsert(item)
        }
    }

    private mutating func upsert(_ item: SessionCleanupItem) {
        if let index = items.firstIndex(where: { $0.key == item.key }) {
            items[index] = item
        } else {
            items.append(item)
        }
    }

    /// Checking N of M worktrees until every worktree is checked, then
    /// sizing N of M removable worktrees.
    private var planStage: CleanupStage {
        let worktrees = items.filter { $0.kind == .worktree }
        let unchecked = worktrees.filter { checking.contains($0.key) }.count
        let toSize = worktrees.filter { $0.action == .remove && !checking.contains($0.key) }.count
        if unchecked == 0, !sizing.isEmpty {
            return .sizing(done: toSize - sizing.count, of: toSize)
        }
        return .checking(done: worktrees.count - unchecked, of: worktrees.count)
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
    /// Per scope, the streamed run's rows and stage (spec §7).
    private(set) var progresses: [SessionCleanupScope: SessionCleanupProgress] = [:]
    /// Per scope, the apply running and its workbench: one cleanup apply
    /// per workbench at a time (spec §3.2), Delete and Clean Up included.
    private var applyRuns: [SessionCleanupScope: (serial: Int, workbenchID: Int64)] = [:]

    /// The Desktop's live terminals, passed as `--live-session` (Go keeps a
    /// worktree a live session works in). AppState wires it to
    /// `TerminalCenter.liveIDs`.
    @ObservationIgnored var liveSessionIDs: () -> Set<Int64> = { [] }
    /// The environment the cleanup child starts from, before the terminal
    /// session variable is dropped. A seam for tests.
    @ObservationIgnored var baseEnvironment: () async -> [String: String] = { await Constants.resolvedEnvironmentAsync() }

    /// nil: the watchtower binary was not found; every run fails with that.
    @ObservationIgnored private let runner: (any SessionCleanupRunning)?
    /// nil: the watchtower binary was not found; every streamed run fails.
    @ObservationIgnored private let streamer: (any SessionCleanupStreaming)?
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

    init(runner: (any SessionCleanupRunning)?, streamer: (any SessionCleanupStreaming)? = nil) {
        self.runner = runner
        self.streamer = streamer
    }

    /// The Workbench page's center: the app's process runner (a runner of
    /// another kind cannot take an environment, so runs then fail as
    /// "binary not found") and `terminals`' live sessions.
    static func forWorkbenches(runner: (any CLIRunnerProtocol)?, terminals: TerminalCenter) -> SessionCleanupCenter {
        let process = runner as? ProcessCLIRunner
        let center = SessionCleanupCenter(runner: process, streamer: process)
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
        _ scope: SessionCleanupScope,
        timeLimit: Duration? = nil,
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
        return await runApply(.session(sessionID), workbenchID: workbenchID, args: args)
    }

    /// Applies exactly `items` — the sweep keys the owner ticked — to
    /// workbench `workbenchID`, as `applyCleanup` does for a session. With
    /// no item nothing runs (Go refuses a sweep apply without `--item`).
    func applySweep(workbenchID: Int64, items: [String]) async -> Bool {
        guard !items.isEmpty else { return true }
        let args = Self.sweepArguments(workbenchID: workbenchID, live: liveSessionIDs(), applying: items)
        return await runApply(.workbench(workbenchID), workbenchID: workbenchID, args: args)
    }

    private func runApply(_ scope: SessionCleanupScope, workbenchID: Int64, args: [String]) async -> Bool {
        let serial = beginRun(scope, phase: .applying)
        applyRuns[scope] = (serial, workbenchID)
        let outcome = await runCleanup(args)
        if applyRuns[scope]?.serial == serial { applyRuns[scope] = nil }
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
        progresses[scope] = nil
        planRuns.removeValue(forKey: scope)?.task.cancel()
    }

    // MARK: Streamed runs (board #1107, spec 2026-10-26 §6/§7)

    func progress(for scope: SessionCleanupScope) -> SessionCleanupProgress? {
        progresses[scope]
    }

    /// True while any cleanup apply of the workbench runs: the screen's, of
    /// either scope, or Delete and Clean Up's.
    func isApplying(workbenchID: Int64) -> Bool {
        applyRuns.values.contains { $0.workbenchID == workbenchID }
    }

    /// Starts the scope's streamed plan in a task the center owns, as
    /// `startPlan` does; a plan of the scope still running is stopped first
    /// and its later lines are dropped (spec §6 "Events never cross runs").
    /// The rows already shown stay until this run's `listed` replaces them.
    /// `workbenchID` is the session's workbench (a sweep's is its scope's).
    /// With `timeLimit` a plan still running after it is stopped and fails.
    /// Ignored while the scope applies.
    @discardableResult
    func startStreamedPlan(
        _ scope: SessionCleanupScope, workbenchID: Int64, timeLimit: Duration? = nil
    ) -> Task<Void, Never> {
        guard cleanupPhase(for: scope) != .applying else { return Task {} }
        let args = streamArguments(scope, workbenchID: workbenchID)
        let serial = beginStreamedRun(scope, phase: .planning, stage: .listing)
        return startOwnedPlan(scope, timeLimit: timeLimit) { center in
            await center.runStreamedPlan(scope, serial: serial, args: args)
        }
    }

    /// Applies exactly `items` to the scope, streamed. Refused (false,
    /// nothing launched) while another cleanup apply of the workbench runs;
    /// with no item nothing runs and that counts as success. A plan of the
    /// scope still running is stopped. The apply itself is never stopped:
    /// cancelling the returned task leaves the CLI running. True when the
    /// CLI ran and no item reported an error.
    @discardableResult
    func startStreamedApply(_ scope: SessionCleanupScope, workbenchID: Int64, items: [String]) -> Task<Bool, Never> {
        guard !items.isEmpty else { return Task { true } }
        guard !isApplying(workbenchID: workbenchID) else { return Task { false } }
        let args = streamArguments(scope, workbenchID: workbenchID, applying: items)
        planRuns.removeValue(forKey: scope)?.task.cancel()
        let serial = beginStreamedRun(scope, phase: .applying, stage: .applying)
        applyRuns[scope] = (serial, workbenchID)
        let applied = Set(items)
        let run = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let outcome = await stream(scope, serial: serial, args: args) { $0.absorbApply($1, applied: applied) }
            if applyRuns[scope]?.serial == serial { applyRuns[scope] = nil }
            switch outcome {
            case let .success(result):
                if runSerials[scope] == serial { phases[scope] = .done(result) }
                return Self.itemFailures(result) == nil
            case let .failure(message):
                if runSerials[scope] == serial { fail(scope, message) }
                return false
            }
        }
        // A separate task: the caller cancelling its own never reaches the apply.
        return Task { await run.value }
    }

    private func runStreamedPlan(_ scope: SessionCleanupScope, serial: Int, args: [String]) async {
        let outcome = await stream(scope, serial: serial, args: args) { [now = self.now] in $0.absorbPlan($1, now: now()) }
        guard runSerials[scope] == serial else { return }
        guard !Task.isCancelled else {
            if let limit = stoppedAtLimit.removeValue(forKey: scope) {
                fail(scope, Self.overLimitText(limit))
            } else {
                phases[scope] = nil
                progresses[scope] = nil
            }
            return
        }
        switch outcome {
        case let .success(plan):
            phases[scope] = .ready(plan)
            readyAt[scope] = now()
        case let .failure(message):
            fail(scope, message)
        }
    }

    private func beginStreamedRun(_ scope: SessionCleanupScope, phase: SessionCleanupPhase, stage: CleanupStage) -> Int {
        let serial = beginRun(scope, phase: phase)
        var progress = progresses[scope] ?? SessionCleanupProgress(runID: serial)
        progress.runID = serial
        progress.removing = []
        progress.stage = stage
        progresses[scope] = progress
        return serial
    }

    private func fail(_ scope: SessionCleanupScope, _ message: String) {
        phases[scope] = .failed(message)
        progresses[scope]?.stage = .failed(message)
    }

    /// Runs one streamed child for the scope's run `serial`: each decoded
    /// line is applied to the scope's progress through `absorb` — in
    /// batches, at most every 100 ms — only while `serial` is the scope's
    /// current run; a bad line or an unknown event is skipped. Cancelling
    /// the calling task stops the child. A stream without `done` is a
    /// failure with the CLI's words. Superseded or cancelled: the outcome
    /// is meaningless and callers drop it.
    private func stream(
        _ scope: SessionCleanupScope,
        serial: Int,
        args: [String],
        absorb: @escaping @MainActor (inout SessionCleanupProgress, SessionCleanupEvent) -> Void
    ) async -> Outcome {
        guard let streamer else { return .failure(CLIRunnerError.binaryNotFound.localizedDescription) }
        let environment = Self.cleanupEnvironment(await baseEnvironment())
        guard runSerials[scope] == serial, !Task.isCancelled else { return .failure("superseded") }
        let child: SessionCleanupStream
        do {
            child = try streamer.streamCleanup(args: args, environment: environment)
        } catch {
            return .failure(error.localizedDescription)
        }
        let isCurrent = { [weak self] in self?.runSerials[scope] == serial }
        let batches = SessionCleanupEventBatches(interval: Self.eventBatchInterval) { [weak self] events in
            guard let self, isCurrent(), var progress = progresses[scope] else { return }
            events.forEach { absorb(&progress, $0) }
            progresses[scope] = progress
        }
        let done: SessionCleanupPlan? = await withTaskCancellationHandler {
            var done: SessionCleanupPlan?
            for await line in child.lines {
                guard isCurrent(), !Task.isCancelled else {
                    child.stop()
                    break
                }
                guard let event = SessionCleanupEvent.decode(line: line) else { continue }
                batches.add(event)
                if case let .done(plan) = event {
                    done = plan
                    batches.flush()
                }
            }
            batches.flush()
            return done
        } onCancel: {
            child.stop()
        }
        guard isCurrent(), !Task.isCancelled else { return .failure("superseded") }
        if let done { return .success(done) }
        let exit = await child.exit()
        return .failure(exit.status == 0 ? Self.endedWithoutResultText : exit.message)
    }

    /// How often streamed events reach the view at most (spec §7).
    nonisolated static let eventBatchInterval: Duration = .milliseconds(100)

    /// A stream that ended cleanly but never said `done`.
    nonisolated static let endedWithoutResultText = "The cleanup check ended without a result."

    private func streamArguments(_ scope: SessionCleanupScope, workbenchID: Int64, applying items: [String]? = nil) -> [String] {
        switch scope {
        case let .session(sessionID):
            Self.cleanupArguments(
                sessionID: sessionID, workbenchID: workbenchID, live: liveSessionIDs(), applying: items, stream: true
            )
        case let .workbench(id):
            Self.sweepArguments(workbenchID: id, live: liveSessionIDs(), applying: items, stream: true)
        }
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
    /// [--apply --item K…] --json [--stream]`. Values travel as
    /// `--flag=value`, so a key is never read as a flag.
    nonisolated static func cleanupArguments(
        sessionID: Int64, workbenchID: Int64, live: Set<Int64>, applying items: [String]? = nil, stream: Bool = false
    ) -> [String] {
        var args = ["workbench", "cleanup", "--session=\(sessionID)", "--workbench=\(workbenchID)"]
        args += live.sorted().map { "--live-session=\($0)" }
        if let items { args += ["--apply"] + items.map { "--item=\($0)" } }
        return args + ["--json"] + (stream ? ["--stream"] : [])
    }

    /// `workbench cleanup --workbench W --sweep [--live-session L]…
    /// [--apply --item K…] --json [--stream]` (spec §4: a sweep names no
    /// session).
    nonisolated static func sweepArguments(
        workbenchID: Int64, live: Set<Int64>, applying items: [String]? = nil, stream: Bool = false
    ) -> [String] {
        var args = ["workbench", "cleanup", "--workbench=\(workbenchID)", "--sweep"]
        args += live.sorted().map { "--live-session=\($0)" }
        if let items { args += ["--apply"] + items.map { "--item=\($0)" } }
        return args + ["--json"] + (stream ? ["--stream"] : [])
    }

    /// "x: git refused …; feat/x: …" over the items whose removal failed;
    /// nil when none did.
    nonisolated static func itemFailures(_ result: SessionCleanupPlan) -> String? {
        let failed = result.items.filter { !$0.error.isEmpty }
        guard !failed.isEmpty else { return nil }
        return failed.map { "\($0.name.isEmpty ? $0.key : $0.name): \($0.error)" }.joined(separator: "; ")
    }
}

/// Coalesces a streamed run's events (spec §7): the first event goes at
/// once, later ones wait until `interval` has passed since the last batch.
@MainActor
private final class SessionCleanupEventBatches {
    private let interval: Duration
    private let deliver: @MainActor ([SessionCleanupEvent]) -> Void
    private var pending: [SessionCleanupEvent] = []
    private var lastBatch: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?

    init(interval: Duration, deliver: @escaping @MainActor ([SessionCleanupEvent]) -> Void) {
        self.interval = interval
        self.deliver = deliver
    }

    func add(_ event: SessionCleanupEvent) {
        pending.append(event)
        guard timer == nil else { return }
        guard let lastBatch, ContinuousClock.now - lastBatch < interval else { return flush() }
        let due = lastBatch + interval
        timer = Task { [weak self] in
            try? await Task.sleep(until: due)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        timer?.cancel()
        timer = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        lastBatch = .now
        deliver(batch)
    }
}
