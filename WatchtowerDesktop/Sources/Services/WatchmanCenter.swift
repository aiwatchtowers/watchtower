import Foundation
import Observation
import WatchtowerCore

/// Settings → Profile → Watchman (#1823, phase 1) over `watchtower watchman …`:
/// `status --json` for the screen, `learn --workbench N --start --json`
/// (Start Learning, after the owner has seen the estimate) and
/// `backtest --workbench N --json` (Run Backtest Now / Retry). App-wide on
/// `AppState`, so a learning pass or a backtest the owner started keeps its
/// busy line when Settings closes and opens again.
///
/// Both owner verbs block until the CLI finishes (a backtest takes minutes);
/// meanwhile `watch()` rereads the status every `pollInterval` for the
/// progress line. Nothing here writes the database.
///
/// Phase 2 (#1823, D47): the arming controls — Hand to Watchman / Take back
/// on the session strip and the target panel, the tray's Hand all running
/// sessions — go through `watchman arm|disarm --json` (one implementation of
/// arming, its sidecar and git hooks) and read the arming from the status.
@MainActor
@Observable
final class WatchmanCenter {
    nonisolated static let pollInterval: Duration = .seconds(3)
    /// A whole backtest: up to 8 × 30 model calls plus the judge.
    nonisolated static let backtestTimeout: TimeInterval = 6 * 3600
    /// The first learning pass runs under its own budget in the CLI.
    nonisolated static let learnTimeout: TimeInterval = 2 * 3600

    private(set) var state: WatchmanSettingsState = .loading
    /// Workbenches whose `learn --start` this app runs now.
    private(set) var learningHere: Set<Int64> = []
    /// Workbenches whose `backtest` this app runs now.
    private(set) var backtestHere: Set<Int64> = []
    /// One line per workbench under its controls: busy, refused, failed.
    private(set) var notices: [Int64: String] = [:]
    /// A reread that failed while a status is on screen: the screen keeps
    /// the last status and shows this line.
    private(set) var readError: String?

    /// The last status read: the arming the controls show; nil before one.
    private(set) var lastStatus: WatchmanStatus?
    /// Arming scopes whose `arm`/`disarm` (or its check) this app runs now.
    private(set) var armingHere: Set<WatchmanArmScope> = []
    /// One line per scope under its control: a failed arm or take back.
    private(set) var armNotices: [WatchmanArmScope: String] = [:]
    /// The arm sheet on screen (the check said a first time or a warning).
    var sheet: WatchmanArmSheetRequest?

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Sessions the status was reread for once because a target was armed
    /// (a session started under it after the last read).
    @ObservationIgnored private var rereadFor: Set<Int64> = []
    @ObservationIgnored private var firstReadStarted = false
    /// Bumped by every read: an older reply never overwrites a newer one.
    @ObservationIgnored private var readToken = 0

    /// `status`: one already read (a design shot draws the controls on it);
    /// the app reads its own on first use.
    init(
        runner: any CLIRunnerProtocol,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        status: WatchmanStatus? = nil
    ) {
        self.runner = runner
        self.sleep = sleep
        lastStatus = status
        daemon = status?.daemon ?? .unknown
    }

    /// `daemon_running` of the last status read; unknown before one, or
    /// from a CLI that does not print it (the journal's daemon line).
    private(set) var daemon: WatchmanDaemonState = .unknown

    /// A learning pass or a backtest is under way here or in the daemon.
    var needsPolling: Bool {
        if !learningHere.isEmpty || !backtestHere.isEmpty { return true }
        return lastStatus?.workbenches.contains { row in
            // A relabel pass runs in the daemon: keep reading until it is done.
            if row.isRelabelling { return true }
            switch WatchmanWorkbenchPhase.of(row) {
            case .learning, .running: return true
            default: return false
            }
        } ?? false
    }

    func phase(of row: WatchmanWorkbenchStatus) -> WatchmanWorkbenchPhase {
        WatchmanWorkbenchPhase.of(
            row, learningHere: learningHere.contains(row.workbench), backtestHere: backtestHere.contains(row.workbench)
        )
    }

    // MARK: - Reads

    func load() async {
        readToken += 1
        let token = readToken
        do {
            let data = try await runner.run(args: ["watchman", "status", "--json"])
            let status = try JSONDecoder().decode(WatchmanStatus.self, from: data)
            guard token == readToken else { return }
            guard status.ok else { return readFailed(Self.replyError(data) ?? "the status reply was not ok") }
            lastStatus = status
            daemon = status.daemon
            readError = nil
            apply()
        } catch {
            guard token == readToken, !(error is CancellationError) else { return }
            readFailed(Self.message(error))
        }
    }

    /// Replaces the section only when no status was read yet.
    private func readFailed(_ message: String) {
        if lastStatus == nil {
            state = .readFailed(message)
        } else {
            readError = message
        }
    }

    /// Reads once, then again every `pollInterval` while something runs.
    /// The view restarts it whenever `needsPolling` changes.
    func watch() async {
        await load()
        while needsPolling, !Task.isCancelled {
            do { try await sleep(Self.pollInterval) } catch { return }
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    // MARK: - Owner verbs

    func startLearning(workbench: Int64) async {
        guard learningHere.insert(workbench).inserted else { return }
        notices[workbench] = nil
        apply()
        let args = ["watchman", "learn", "--workbench", String(workbench), "--start", "--json"]
        let failure = await call(args, timeout: Self.learnTimeout).failure
        learningHere.remove(workbench)
        if let failure { notices[workbench] = WatchmanSettingsCopy.learnFailed(failure) }
        await load()
    }

    func runBacktest(workbench: Int64) async {
        // Reads the last polled status; the CLI's own refusal while the relabel pass is unfinished is the backstop.
        guard lastStatus?.workbench(workbench)?.isRelabelling != true else { return }
        guard backtestHere.insert(workbench).inserted else { return }
        notices[workbench] = nil
        apply()
        let args = ["watchman", "backtest", "--workbench", String(workbench), "--json"]
        let outcome = await call(args, timeout: Self.backtestTimeout)
        backtestHere.remove(workbench)
        // A run that started and failed is a `failed` row the status shows
        // with its error; the notice is only for a call that never got that far.
        if let failure = outcome.failure, !Self.hasBacktestRow(outcome.stdout) {
            notices[workbench] = failure == "busy" ? WatchmanSettingsCopy.busy : failure
        }
        await load()
    }

    // MARK: - Arming

    /// `arm` and `disarm` print their reply at once, after the branch
    /// protection check (15 s budget) at most.
    nonisolated static let armTimeout: TimeInterval = 120

    /// Reads the status when the controls have none, or when a target is
    /// armed and this session is not known armed yet (it may have started
    /// under that target since the last read) — once per session.
    func loadIfNeeded(for scope: WatchmanArmScope) async {
        guard let status = lastStatus else {
            // Several strips appear at once: one first read for them all.
            guard !firstReadStarted else { return }
            firstReadStarted = true
            return await load()
        }
        guard case let .session(id) = scope, status.armed.contains(where: { $0.scope == .target }),
              !status.isArmed(session: id), rereadFor.insert(id).inserted else { return }
        await load()
    }

    /// Hand to Watchman on a control: `arm --check` first; a first time on
    /// the workbench or a warning opens the arm sheet, otherwise it arms.
    func handTo(_ scope: WatchmanArmScope, workbench: String) async {
        guard armingHere.insert(scope).inserted else { return }
        armNotices[scope] = nil
        let check = await check(scope)
        armingHere.remove(scope)
        switch check {
        case let .failed(message):
            armNotices[scope] = WatchmanArmingCopy.armFailed(message)
        case let .reply(reply) where reply.needsSheet:
            sheet = WatchmanArmSheetRequest(scope: scope, content: WatchmanArmSheetContent(workbench: workbench, reply: reply))
        case .reply:
            await arm(scope)
        }
    }

    /// The arm sheet's Hand to Watchman: arms its scope and closes it.
    func confirmSheet() async {
        guard let request = sheet else { return }
        sheet = nil
        await arm(request.scope)
    }

    /// `watchman arm --check`: writes nothing.
    func check(_ scope: WatchmanArmScope) async -> WatchmanArmCheck {
        let outcome = await call(["watchman", "arm"] + scope.flags() + ["--check", "--json"], timeout: Self.armTimeout)
        if let failure = outcome.failure { return .failed(failure) }
        guard let reply = try? JSONDecoder().decode(WatchmanArmReply.self, from: outcome.stdout) else {
            return .failed("the reply could not be read")
        }
        return .reply(reply)
    }

    /// `watchman arm`, then the status again. A failure is the scope's notice.
    @discardableResult
    func arm(_ scope: WatchmanArmScope) async -> WatchmanArmReply? {
        armingHere.insert(scope)
        armNotices[scope] = nil
        let outcome = await call(["watchman", "arm"] + scope.flags() + ["--json"], timeout: Self.armTimeout)
        armingHere.remove(scope)
        let reply = try? JSONDecoder().decode(WatchmanArmReply.self, from: outcome.stdout)
        if let failure = outcome.failure ?? (reply == nil ? "the reply could not be read" : nil) {
            armNotices[scope] = WatchmanArmingCopy.armFailed(failure)
        } else if let reply {
            armNotices[scope] = Self.armedNotice(scope, reply)
        }
        await load()
        return outcome.failure == nil ? reply : nil
    }

    /// Take back: `watchman disarm`, then the status again.
    func disarm(_ scope: WatchmanArmScope) async {
        guard armingHere.insert(scope).inserted else { return }
        armNotices[scope] = nil
        let outcome = await call(["watchman", "disarm"] + scope.flags(disarm: true) + ["--json"], timeout: Self.armTimeout)
        armingHere.remove(scope)
        if let failure = outcome.failure { armNotices[scope] = WatchmanArmingCopy.takeBackFailed(failure) }
        await load()
    }

    /// The tray's Hand all running sessions to Watchman: no sheet (a menu
    /// has no room for one), so what the sheet would say becomes the tray's
    /// notice lines.
    func handAllRunning() async {
        guard !armingHere.contains(.allRunning) else { return }
        await arm(.allRunning)
    }

    /// What stays under a control after a successful arm: the tray, which
    /// had no sheet, gets the D21 line and the warnings; every scope the
    /// sidecar note.
    private static func armedNotice(_ scope: WatchmanArmScope, _ reply: WatchmanArmReply) -> String? {
        var lines: [String] = []
        if scope == .allRunning {
            if reply.analyticsTurnedOn { lines.append(WatchmanArmingCopy.analyticsLine) }
            lines += reply.warnings
        }
        if !reply.sidecarError.isEmpty { lines.append(WatchmanArmingCopy.sidecarNote) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Private

    private func apply() {
        guard let status = lastStatus else { return }
        state = .of(status, learningHere: learningHere, backtestHere: backtestHere)
    }

    /// Runs an owner verb: its stdout and, unless it succeeded, its error
    /// line (`"busy"` when the Watchman lock is held).
    private func call(_ args: [String], timeout: TimeInterval) async -> (failure: String?, stdout: Data) {
        do {
            let result = try await runner.capture(args: args, timeout: timeout)
            if let error = Self.replyError(result.stdout) { return (error, result.stdout) }
            guard result.exitCode != 0 else { return (nil, result.stdout) }
            let line = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return (line ?? (result.exitCode == -1 ? "timed out" : "exit code \(result.exitCode)"), result.stdout)
        } catch {
            return (Self.message(error), Data())
        }
    }

    /// The backtest reply names its row (`backtest_id`/`status`): the run
    /// started, so its outcome is the row's.
    private static func hasBacktestRow(_ data: Data) -> Bool {
        struct Reply: Decodable {
            let backtestID: Int64?
            let status: String?

            enum CodingKeys: String, CodingKey {
                case status
                case backtestID = "backtest_id"
            }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return false }
        return (reply.backtestID ?? 0) > 0 || !(reply.status ?? "").isEmpty
    }

    /// The `error` of a `{"ok":false,"error":…}` reply; nil for any other.
    private static func replyError(_ data: Data) -> String? {
        struct Reply: Decodable {
            let ok: Bool
            let error: String?
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data), !reply.ok else { return nil }
        return reply.error.flatMap { $0.isEmpty ? nil : $0 } ?? "failed"
    }

    private static func message(_ error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let line = stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return line ?? (code == -1 ? "timed out" : "exit code \(code)")
        }
        return SessionReportCenter.errorLine(error)
    }
}

/// The arm sheet of one control: the scope it arms and what it shows.
struct WatchmanArmSheetRequest: Identifiable, Equatable {
    let scope: WatchmanArmScope
    let content: WatchmanArmSheetContent
    var id: WatchmanArmScope { scope }
}
