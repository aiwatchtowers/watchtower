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
/// progress line. Phase 2 adds editing (`editing`): each learned workbench's
/// `profile --json` with `profile set|unpin` (category texts and the sleep
/// window) and `limits list|add|remove`. Every write goes through the CLI;
/// nothing here writes the database.
@MainActor
@Observable
final class WatchmanCenter {
    nonisolated static let pollInterval: Duration = .seconds(3)
    /// A whole backtest: up to 8 × 30 model calls plus the judge.
    nonisolated static let backtestTimeout: TimeInterval = 6 * 3600
    /// The first learning pass runs under its own budget in the CLI.
    nonisolated static let learnTimeout: TimeInterval = 2 * 3600
    /// `profile set|unpin`, `limits add|remove`: one row write each.
    nonisolated static let editTimeout: TimeInterval = 60

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
    /// Profiles, limits and the lines of their failed reads and edits.
    private(set) var editing = WatchmanEditingData()

    @ObservationIgnored private let runner: any CLIRunnerProtocol
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var lastStatus: WatchmanStatus?
    /// Bumped by every read: an older reply never overwrites a newer one.
    @ObservationIgnored private var readToken = 0
    /// Bumped by every limits read, and per workbench by every profile read.
    @ObservationIgnored private var limitsToken = 0
    @ObservationIgnored private var profileTokens: [Int64: Int] = [:]
    /// Learned workbenches whose profile read ended (read or failed) since
    /// the last `refresh()`; a cancelled read leaves its workbench out, so
    /// the next read retries it.
    @ObservationIgnored private var profilesAsked: Set<Int64> = []

    init(
        runner: any CLIRunnerProtocol,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runner = runner
        self.sleep = sleep
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
        // Also after a failed read: the workbenches of the last status read.
        await loadNewProfiles()
    }

    /// Reads everything again: the status, each learned workbench's
    /// profile and the limits. Opening Settings and **Retry** run it.
    func refresh() async {
        profilesAsked.removeAll()
        await load()
        await loadLimits()
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
        await refresh()
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

    // MARK: - Editing (phase 2)

    /// Reads the profile of each workbench the last status shows learned
    /// and whose read has not ended since `refresh()`, also while polling
    /// goes on for another. A failed read keeps what was read before and
    /// shows its line.
    private func loadNewProfiles() async {
        for row in lastStatus?.workbenches ?? [] where row.isLearned && !profilesAsked.contains(row.workbench) {
            if await loadProfile(workbench: row.workbench) { profilesAsked.insert(row.workbench) }
        }
    }

    private func loadLimits() async {
        limitsToken += 1
        let token = limitsToken
        do {
            let data = try await runner.run(args: ["watchman", "limits", "list", "--json"])
            let limits = try JSONDecoder().decode(WatchmanLimits.self, from: data)
            guard token == limitsToken else { return }
            editing.limits = limits
            editing.limitsReadError = nil
        } catch {
            guard token == limitsToken, !(error is CancellationError) else { return }
            editing.limitsReadError = Self.message(error)
        }
    }

    /// False when the read was cancelled: nothing changed.
    @discardableResult
    private func loadProfile(workbench: Int64) async -> Bool {
        let token = (profileTokens[workbench] ?? 0) + 1
        profileTokens[workbench] = token
        do {
            let data = try await runner.run(args: ["watchman", "profile", "--workbench", String(workbench), "--json"])
            let profile = try JSONDecoder().decode(WatchmanProfile.self, from: data)
            guard profileTokens[workbench] == token else { return true }
            editing.profiles[workbench] = profile
            editing.profileReadErrors[workbench] = nil
        } catch {
            if error is CancellationError { return false }
            guard profileTokens[workbench] == token else { return true }
            editing.profileReadErrors[workbench] = Self.message(error)
        }
        return true
    }

    /// Saves and pins a category's text or, under `sleep_window`, the sleep
    /// window: checked here first (the window's `HH:MM-HH:MM`, a text's 1–20
    /// lines), then written to a temporary file for `profile set
    /// --text-file`. True once saved, so the editor closes; otherwise the
    /// entry's line says why.
    @discardableResult
    func saveProfile(workbench: Int64, key: String, text: String) async -> Bool {
        let slot = WatchmanEditSlot.profile(workbench: workbench, key: key)
        let checked = key == WatchmanProfileEntry.sleepWindowKey ? Self.sleepWindow(text) : Self.profileText(text)
        let value: String
        switch checked {
        case let .success(text): value = text
        case let .failure(problem):
            editing.errors[slot] = problem.line
            return false
        }
        guard editing.saving.insert(slot).inserted else { return false }
        defer { editing.saving.remove(slot) }
        editing.errors[slot] = nil
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchman-profile-\(UUID().uuidString).txt")
        do {
            try Data(value.utf8).write(to: file, options: .atomic)
        } catch {
            editing.errors[slot] = WatchmanSettingsCopy.saveFailed(SessionReportCenter.errorLine(error))
            return false
        }
        // The CLI has read it by the time it exits; a leftover file in the temporary directory is harmless.
        defer { try? FileManager.default.removeItem(at: file) }
        let args = ["watchman", "profile", "set", "--workbench", String(workbench), "--key", key,
                    "--text-file", file.path]
        if let failure = await call(args, timeout: Self.editTimeout).failure {
            editing.errors[slot] = WatchmanSettingsCopy.saveFailed(failure)
            return false
        }
        await reloadAfterProfileChange(workbench: workbench, key: key)
        return true
    }

    /// Unpins an entry: the next weekly rebuild replaces it.
    func unpin(workbench: Int64, key: String) async {
        let slot = WatchmanEditSlot.profile(workbench: workbench, key: key)
        guard editing.saving.insert(slot).inserted else { return }
        defer { editing.saving.remove(slot) }
        editing.errors[slot] = nil
        let args = ["watchman", "profile", "unpin", "--workbench", String(workbench), "--key", key]
        if let failure = await call(args, timeout: Self.editTimeout).failure {
            editing.errors[slot] = WatchmanSettingsCopy.unpinFailed(failure)
            return
        }
        await reloadAfterProfileChange(workbench: workbench, key: key)
    }

    /// Adds an owner's limit after the same checks the CLI makes
    /// (`ValidateLimitPattern`; an unclosed quote is left to the CLI, whose
    /// error shows). True once added, so the form closes.
    @discardableResult
    func addLimit(kind: WatchmanLimitKind, pattern: String) async -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = Self.limitProblem(kind: kind, pattern: pattern) {
            editing.errors[.limits] = problem
            return false
        }
        guard editing.saving.insert(.limits).inserted else { return false }
        defer { editing.saving.remove(.limits) }
        editing.errors[.limits] = nil
        // `=` keeps a pattern that starts with "-" a value, not a flag.
        let args = ["watchman", "limits", "add", "--kind=\(kind.rawValue)", "--pattern=\(pattern)"]
        if let failure = await call(args, timeout: Self.editTimeout).failure {
            editing.errors[.limits] = WatchmanSettingsCopy.addFailed(failure)
            return false
        }
        await loadLimits()
        return true
    }

    /// Removes an owner's limit; a built-in row has no id to pass.
    func removeLimit(id: Int64) async {
        guard editing.saving.insert(.limits).inserted else { return }
        defer { editing.saving.remove(.limits) }
        editing.errors[.limits] = nil
        if let failure = await call(["watchman", "limits", "remove", "--id", String(id)], timeout: Self.editTimeout).failure {
            editing.errors[.limits] = WatchmanSettingsCopy.removeFailed(failure)
            return
        }
        await loadLimits()
    }

    /// Drops an edit's line (the owner cancelled or opened the editor again).
    func clearError(_ slot: WatchmanEditSlot) {
        editing.errors[slot] = nil
    }

    private func reloadAfterProfileChange(workbench: Int64, key: String) async {
        await loadProfile(workbench: workbench)
        // The sleep section reads the window and its pin from the status.
        if key == WatchmanProfileEntry.sleepWindowKey { await load() }
    }

    struct EditProblem: Error, Equatable {
        let line: String
    }

    /// `"00:30-07:45"` as the CLI stores it (ASCII digits only); the edges
    /// are trimmed, and an en dash (as the screen shows it) and spaces
    /// around the dash are accepted.
    static func sleepWindow(_ text: String) -> Result<String, EditProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "–", with: "-")
        let window = #/(?<start>(?:[01][0-9]|2[0-3]):[0-5][0-9]) *- *(?<end>(?:[01][0-9]|2[0-3]):[0-5][0-9])/#
        guard let match = trimmed.wholeMatch(of: window) else {
            return .failure(EditProblem(line: WatchmanSettingsCopy.sleepBadFormat))
        }
        return .success("\(match.output.start)-\(match.output.end)")
    }

    /// A category text: its non-blank lines, 1 to 20 of them.
    static func profileText(_ text: String) -> Result<String, EditProblem> {
        let lines = WatchmanProfileEntry(key: "", text: text, pinned: false, updatedAt: "").lines
        if lines.isEmpty { return .failure(EditProblem(line: WatchmanSettingsCopy.profileEmptyText)) }
        if lines.count > WatchmanProfileEntry.maxLines {
            return .failure(EditProblem(line: WatchmanSettingsCopy.profileTooLong(lines: lines.count)))
        }
        return .success(lines.joined(separator: "\n"))
    }

    /// The form's line for a pattern the CLI would refuse; nil when it may go.
    static func limitProblem(kind: WatchmanLimitKind, pattern: String) -> String? {
        if pattern.isEmpty { return WatchmanSettingsCopy.limitEmptyPattern }
        if pattern.contains(where: \.isNewline) { return WatchmanSettingsCopy.limitOneLine }
        if kind == .tool, pattern.contains(where: \.isWhitespace) { return WatchmanSettingsCopy.limitToolBlanks }
        return nil
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
