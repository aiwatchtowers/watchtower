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

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var lastStatus: WatchmanStatus?
    /// Bumped by every read: an older reply never overwrites a newer one.
    @ObservationIgnored private var readToken = 0

    init(
        runner: any CLIRunnerProtocol,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runner = runner
        self.sleep = sleep
    }

    /// A learning pass or a backtest is under way here or in the daemon.
    var needsPolling: Bool {
        if !learningHere.isEmpty || !backtestHere.isEmpty { return true }
        return lastStatus?.workbenches.contains { row in
            switch WatchmanWorkbenchPhase.of(row) {
            case .learning, .running: true
            default: false
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
            guard status.ok else {
                state = .readFailed(Self.replyError(data) ?? "the status reply was not ok")
                return
            }
            lastStatus = status
            apply()
        } catch {
            guard token == readToken, !(error is CancellationError) else { return }
            state = .readFailed(Self.message(error))
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
        let failure = await call(args, timeout: Self.learnTimeout)
        learningHere.remove(workbench)
        if let failure { notices[workbench] = WatchmanSettingsCopy.learnFailed(failure) }
        await load()
    }

    func runBacktest(workbench: Int64) async {
        guard backtestHere.insert(workbench).inserted else { return }
        notices[workbench] = nil
        apply()
        let args = ["watchman", "backtest", "--workbench", String(workbench), "--json"]
        let failure = await call(args, timeout: Self.backtestTimeout)
        backtestHere.remove(workbench)
        // A run that started and failed is a `failed` row the status shows;
        // the notice is for a call that never got that far.
        if let failure { notices[workbench] = failure == "busy" ? WatchmanSettingsCopy.busy : failure }
        await load()
    }

    // MARK: - Private

    private func apply() {
        guard let status = lastStatus else { return }
        state = .of(status, learningHere: learningHere, backtestHere: backtestHere)
    }

    /// Runs an owner verb; nil on success, else its error line (`"busy"` when
    /// the Watchman lock is held).
    private func call(_ args: [String], timeout: TimeInterval) async -> String? {
        do {
            let result = try await runner.capture(args: args, timeout: timeout)
            if let error = Self.replyError(result.stdout) { return error }
            guard result.exitCode != 0 else { return nil }
            let line = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
            return line ?? (result.exitCode == -1 ? "timed out" : "exit code \(result.exitCode)")
        } catch {
            return Self.message(error)
        }
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
