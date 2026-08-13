import Foundation
import GRDB
import WatchtowerCore

/// Drives the multi-site Jira connections shown in Settings → Jira and the
/// add-site sheet. Each row is a DB-backed `jira_accounts` record — any number
/// of Atlassian sites side by side, each independently granting access via its
/// own OAuth consent flow and carrying its own token file. Owned by AppState
/// so the accounts list and any in-flight connect survive navigating away from
/// Settings. Deliberate structural copy of `SlackAccountsViewModel` (house
/// pattern) — `jira add`/`jira login` are browser-consent flows like
/// `slack add`/`slack login`. Unlike those, the Jira CLI has no `--app-return`
/// flag yet, so consent finishes in the system browser instead of returning
/// into the app's WKWebView; closing that divergence is pending an owner
/// decision.
@MainActor
@Observable
final class JiraAccountsViewModel {
    private(set) var accounts: [JiraAccount] = []
    var isConnecting = false
    var error: String?

    private let dbPool: DatabasePool
    private var authProcess: Process?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Refresh

    /// Cross-process writes (the CLI subprocess, or the daemon's Jira syncers)
    /// don't fire GRDB's ValueObservation, so callers reload on appear / after
    /// a CLI call completes rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `accounts` deterministically instead of racing a
    /// detached `Task`.
    func refreshAsync() async {
        do {
            let rows = try await dbPool.read { db in try JiraAccountQueries.fetchAll(db) }
            self.accounts = rows
        } catch {
            self.error = "Failed to load accounts: \(error.localizedDescription)"
        }
    }

    // MARK: - Add

    /// Builds the `jira add` args with an optional `--label` and `--site`.
    /// Pure and side-effect-free so the flag assembly is directly testable
    /// without shelling out to a real process.
    ///
    /// `--site` matters because the CLI's site picker is an interactive stdin
    /// prompt: a grant that reaches several Atlassian sites cannot be resolved
    /// from a spawned process, so the sheet lets the user name the site up
    /// front.
    static func addArgs(label: String, site: String = "") -> [String] {
        var args = ["jira", "add"]
        if !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }
        if !site.isEmpty {
            args.append(contentsOf: ["--site", site])
        }
        return args
    }

    /// Connects a new Atlassian site via `watchtower jira add`. The OAuth
    /// consent happens in the loopback browser; the detached Process is held in
    /// `authProcess` so `cancelConnect()` can terminate it mid-flow.
    func addAccount(label: String, site: String = "") async {
        await runAuthFlow(args: Self.addArgs(label: label, site: site), failurePrefix: "Connect failed")
    }

    // MARK: - Re-login

    /// Builds the `jira login` args for re-consenting an existing account.
    /// Pure and side-effect-free.
    static func loginArgs(for account: JiraAccount) -> [String] {
        ["jira", "login", "--account", String(account.id)]
    }

    /// Re-consents `account` via `watchtower jira login --account <id>` — same
    /// OAuth loopback-browser flow shape as `addAccount`, used when an
    /// account's status is "error"/"revoked" and needs a fresh grant.
    func relogin(_ account: JiraAccount) async {
        await runAuthFlow(args: Self.loginArgs(for: account), failurePrefix: "Re-login failed")
    }

    func cancelConnect() {
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        authProcess = nil
        isConnecting = false
    }

    // MARK: - Enable / Disable

    /// Builds the CLI args to enable or disable `account` — `jira enable <id>`
    /// or `jira disable <id>`. Pure and side-effect-free.
    static func setEnabledArgs(for account: JiraAccount, enabled: Bool) -> [String] {
        ["jira", enabled ? "enable" : "disable", String(account.id)]
    }

    /// Enables or disables `account` via `watchtower jira enable|disable <id>`.
    /// A disabled account stops syncing but keeps all its already-synced data.
    func setEnabled(_ account: JiraAccount, enabled: Bool) async {
        await runManagementCommand(
            args: Self.setEnabledArgs(for: account, enabled: enabled),
            failurePrefix: enabled ? "Enable failed" : "Disable failed"
        )
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `jira remove <id>`.
    /// Pure and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for account: JiraAccount) -> [String] {
        ["jira", "remove", String(account.id)]
    }

    /// Removes `account` via `watchtower jira remove <id>`. Non-destructive:
    /// the CLI deletes the token file and marks the row removed/disabled but
    /// keeps already-synced issues, boards, and releases.
    func remove(_ account: JiraAccount) async {
        await runManagementCommand(args: Self.removeArgs(for: account), failurePrefix: "Remove failed")
    }

    // MARK: - Flow helpers

    /// Browser-consent flow (`add`/`login`) — holds the detached Process in
    /// `authProcess` so `cancelConnect()` can terminate it while this awaits.
    private func runAuthFlow(args: [String], failurePrefix: String) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isConnecting = true
        error = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        let result = await Self.runProcess(process)
        authProcess = nil
        isConnecting = false
        applyResult(result, failurePrefix: failurePrefix)
    }

    /// Non-browser management command (`enable`/`disable`/`remove`) — a plain
    /// awaited CLI invocation, no `authProcess` to cancel.
    private func runManagementCommand(args: [String], failurePrefix: String) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isConnecting = true
        error = nil

        let result = await Self.runCLI(path: cliPath, arguments: args)
        isConnecting = false
        applyResult(result, failurePrefix: failurePrefix)
    }

    private func applyResult(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        failurePrefix: String
    ) {
        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the account set change takes effect now.
            Task { await DaemonManager.restart() }
        } else if result.exitCode == 15 || result.exitCode == 9 {
            // SIGTERM/SIGKILL — user cancelled
            error = nil
        } else {
            error = result.stderr.isEmpty
                ? "\(failurePrefix) (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
        }
    }

    // MARK: - CLI Helpers

    nonisolated private static func runCLI(
        path: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        return await runProcess(process)
    }

    /// Runs a pre-configured Process, reading pipe data before waitUntilExit to
    /// avoid deadlock when output exceeds the pipe buffer.
    nonisolated private static func runProcess(
        _ process: Process
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        // Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds 64KB
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }
}
