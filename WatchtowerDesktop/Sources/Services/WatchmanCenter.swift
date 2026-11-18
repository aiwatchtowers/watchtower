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
    /// The status read the controls started and that runs now: controls
    /// appearing together share it.
    @ObservationIgnored private var inFlightRead: Task<Void, Never>?
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

    /// Why the controls have no fresh arming to show: the last read failed
    /// (with or without an older status on screen); nil otherwise.
    var armingReadError: String? {
        if let readError { return readError }
        if case let .readFailed(message) = state { return message }
        return nil
    }

    /// Rereads the status for a control, the panel or the tray that became
    /// visible (an arm made elsewhere shows then). No timer: only appearing
    /// rereads. Reads already running are shared, not repeated.
    func reread() async {
        if let inFlightRead { return await inFlightRead.value }
        let read = Task { await load() }
        inFlightRead = read
        await read.value
        inFlightRead = nil
    }

    /// Hand to Watchman: `arm --check` first; a first time on a workbench or
    /// a warning opens the arm sheet, otherwise it arms. `workbench` names
    /// the sheet (nil: every running session, the tray). True when the
    /// sheet opened — the tray then brings the main window up for it.
    @discardableResult
    func handTo(_ scope: WatchmanArmScope, workbench: String?) async -> Bool {
        guard armingHere.insert(scope).inserted else { return false }
        armNotices[scope] = nil
        let check = await check(scope)
        armingHere.remove(scope)
        switch check {
        case let .failed(message):
            armNotices[scope] = WatchmanArmingCopy.armFailed(message)
            return false
        case let .reply(reply) where reply.needsSheet:
            let title = workbench.map(WatchmanArmingCopy.sheetTitle(workbench:)) ?? WatchmanArmingCopy.sheetTitleAllRunning
            sheet = WatchmanArmSheetRequest(
                scope: scope, title: title, sessions: reply.sessions,
                content: WatchmanArmSheetContent(title: title, reply: reply))
            return true
        case .reply:
            await arm(scope)
            return false
        }
    }

    /// The tray's Hand all running sessions to Watchman: the same check and
    /// sheet as a control's. True when the sheet opened.
    func handAllRunning() async -> Bool {
        await handTo(.allRunning, workbench: nil)
    }

    /// The arm sheet's Hand to Watchman: arms its scope and closes it.
    /// Every running session (the tray) is checked again first: when the
    /// running set changed since the sheet opened, the sheet shows the new
    /// set and asks again; otherwise exactly the confirmed sessions are armed
    /// (`--only`), so a session started meanwhile is never armed unseen.
    func confirmSheet() async {
        guard let request = sheet else { return }
        guard request.scope == .allRunning else {
            sheet = nil
            await arm(request.scope)
            return
        }
        switch await check(.allRunning) {
        case let .failed(message):
            sheet = nil
            armNotices[.allRunning] = WatchmanArmingCopy.armFailed(message)
        case let .reply(reply) where Set(reply.sessions) != Set(request.sessions):
            sheet = WatchmanArmSheetRequest(
                scope: .allRunning, title: request.title, sessions: reply.sessions,
                content: WatchmanArmSheetContent(title: request.title, reply: reply,
                                                 notice: WatchmanArmingCopy.sessionsChanged))
        case .reply:
            sheet = nil
            await arm(.allRunning, only: request.sessions)
        }
    }

    /// `watchman arm --check`: writes nothing.
    func check(_ scope: WatchmanArmScope) async -> WatchmanArmCheck {
        let outcome = await call(["watchman", "arm"] + scope.flags() + ["--check", "--json"], timeout: Self.armTimeout)
        if let failure = outcome.failure { return .failed(failure) }
        guard let reply = try? JSONDecoder().decode(WatchmanArmReply.self, from: outcome.stdout) else {
            return .failed(WatchmanArmingCopy.replyUnreadable)
        }
        return .reply(reply)
    }

    /// `watchman arm`, then the status again. The scope's notice is the
    /// failure, or what the reply has to say (warnings, the D21 line, the
    /// sidecar note); an unreadable reply after exit 0 lets the status say.
    @discardableResult
    func arm(_ scope: WatchmanArmScope, only: [Int64] = []) async -> WatchmanArmReply? {
        armingHere.insert(scope)
        armNotices[scope] = nil
        let onlyFlags = only.isEmpty ? [] : ["--only", only.map(String.init).joined(separator: ",")]
        let outcome = await call(["watchman", "arm"] + scope.flags() + onlyFlags + ["--json"], timeout: Self.armTimeout)
        armingHere.remove(scope)
        let reply = try? JSONDecoder().decode(WatchmanArmReply.self, from: outcome.stdout)
        if let failure = outcome.failure {
            armNotices[scope] = WatchmanArmingCopy.armFailed(failure)
        } else if let reply {
            armNotices[scope] = WatchmanArmingCopy.armedNotice(reply)
        } else {
            armNotices[scope] = WatchmanArmingCopy.rereading
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
        if let failure = outcome.failure {
            armNotices[scope] = WatchmanArmingCopy.takeBackFailed(failure)
        } else if let reply = try? JSONDecoder().decode(WatchmanDisarmReply.self, from: outcome.stdout),
                  !reply.sidecarError.isEmpty {
            armNotices[scope] = WatchmanArmingCopy.takeBackSidecarNote
        }
        await load()
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
    let title: String
    /// The sessions the check covered: the set the owner confirms.
    let sessions: [Int64]
    let content: WatchmanArmSheetContent
    var id: WatchmanArmScope { scope }
}
