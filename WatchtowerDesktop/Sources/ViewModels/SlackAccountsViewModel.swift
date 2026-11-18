import Foundation
import GRDB
import WatchtowerCore

/// Drives the multi-workspace Slack connections shown in Connections → Slack and
/// the add-workspace sheet. Each row is a DB-backed `slack_accounts` record —
/// any number of Slack workspaces side by side, each independently granting
/// access via its own OAuth consent flow and carrying its own namespaced
/// identity. Owned by AppState so the accounts list and any in-flight connect
/// survive navigating away from Settings. Deliberate structural copy of
/// `GoogleAccountsViewModel` (house pattern) — `slack add`/`slack login` are
/// browser-consent flows like `google add`/`google login`.
@MainActor
@Observable
final class SlackAccountsViewModel {
    private(set) var accounts: [SlackAccount] = []
    var isConnecting = false
    var error: String?
    /// The last account read failed; nil once one succeeds. Only the read:
    /// an action's failure stays in `error` (the Connections tab's
    /// "Couldn't read accounts" reads this).
    private(set) var readError: String?
    /// The last successful remove's warning that Slack did not confirm the
    /// token revoke (`SlackRevokeNotice`, #1769); nil when it did. A
    /// non-blocking notice, cleared by the next management command
    /// (enable, disable, remove).
    private(set) var revokeNotice: String?

    /// The restart the last successful account change kicked off under
    /// `.restart` (nil under `.deferred`) — held so tests can await it.
    @ObservationIgnored private(set) var daemonRestartTask: Task<Void, Never>?

    private let dbPool: DatabasePool
    private let daemon: any DaemonRestarting
    /// Resolves the CLI binary; injectable so tests can run a stand-in.
    private let cliPath: () -> String?
    private var authProcess: Process?
    /// The sign-in child's environment; injectable so tests can hold it.
    @ObservationIgnored var loginEnvironment: @Sendable () async -> [String: String] = {
        await Constants.resolvedEnvironmentAsync()
    }

    init(
        dbPool: DatabasePool,
        daemon: any DaemonRestarting = LiveDaemonRestarter(),
        cliPath: @escaping () -> String? = Constants.findCLIPath
    ) {
        self.dbPool = dbPool
        self.daemon = daemon
        self.cliPath = cliPath
    }

    // MARK: - Refresh

    /// Called after every successful reload — every account change this VM
    /// makes ends in one. Injected by AppState, which re-resolves the owner
    /// identity here (OWNER-01; the CatchUp `onRecapsChanged` precedent).
    var onAccountsChanged: (() async -> Void)?

    /// Cross-process writes (the CLI subprocess, or the daemon's Slack syncers)
    /// don't fire GRDB's ValueObservation, so callers reload on appear / after a
    /// CLI call completes rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `accounts` deterministically instead of racing a
    /// detached `Task`.
    func refreshAsync() async {
        do {
            let rows = try await dbPool.read { db in try SlackAccountQueries.fetchAll(db) }
            self.accounts = rows
            readError = nil
            await onAccountsChanged?()
        } catch {
            self.error = "Failed to load accounts: \(error.localizedDescription)"
            readError = self.error
        }
    }

    // MARK: - Add

    /// The `slack add` args — always `--app-return` (the CLI opens
    /// watchtower-auth:// once consent is done, so macOS brings the app back to
    /// the foreground). No `--label`: the CLI names the workspace after its team
    /// (`db.SlackAccountLabel`); the owner renames it in Settings.
    static let addArgs = ["slack", "add", "--app-return"]

    /// Connects a new Slack workspace via `watchtower slack add --app-return`.
    /// The OAuth consent happens in the loopback browser; the detached Process
    /// is held in `authProcess` so `cancelConnect()` can terminate it mid-flow.
    func addAccount(daemonPolicy: DaemonRestartPolicy = .restart) async {
        await runAuthFlow(args: Self.addArgs, failurePrefix: "Connect failed", daemonPolicy: daemonPolicy)
    }

    // MARK: - Re-login

    /// Builds the `slack login` args for re-consenting an existing account.
    /// Pure and side-effect-free.
    static func loginArgs(for account: SlackAccount) -> [String] {
        ["slack", "login", "--account", String(account.id), "--app-return"]
    }

    /// The connect flow on `AppState` (plan B #1709); nil under XCTest or
    /// without the CLI, where Re-login keeps `slack login`.
    @ObservationIgnored weak var connectFlow: SlackConnectFlowModel?

    /// Re-consents `account` by its route in `slack accounts --json` (plan B
    /// A7): the build's own app re-runs `watchtower slack login --account <id>
    /// --app-return`; a workspace app goes through the connect flow on the
    /// Desktop's running listener (a `slack login` would bind 18551, which
    /// that listener holds); no app to sign in with opens the connect section.
    /// Returns the route taken; nil when nothing started (`error` says why).
    @discardableResult
    func relogin(_ account: SlackAccount) async -> SlackReloginRoute? {
        guard let flow = connectFlow else {
            await runAuthFlow(args: Self.loginArgs(for: account), failurePrefix: "Re-login failed", daemonPolicy: .restart)
            return .builtin
        }
        let route: SlackReloginRoute
        switch await reloginRoute(accountID: Int64(account.id)) {
        case let .failure(failure):
            error = failure.message
            return nil
        case let .success(found):
            route = found
        }
        guard route == .builtin else {
            guard flow.reconnect(route) else {
                error = "Another connection is already in progress."
                return nil
            }
            return route
        }
        // One flow at a time: the built-in sign-in waits for the connect flow too.
        guard !flow.isRunning else {
            error = "Another connection is already in progress."
            return nil
        }
        await runAuthFlow(args: Self.loginArgs(for: account), failurePrefix: "Re-login failed", daemonPolicy: .restart)
        return route
    }

    /// The route of account `accountID` from `slack accounts --json`, or why
    /// it could not be read. Shown as connecting while it reads, so no other
    /// sign-in starts meanwhile; leaves `error` to the caller.
    func reloginRoute(accountID: Int64) async -> Result<SlackReloginRoute, RouteReadError> {
        guard !isConnecting else { return .failure(RouteReadError("Another connection is already in progress.")) }
        guard let cliPath = cliPath() else { return .failure(RouteReadError("Watchtower CLI not found")) }
        isConnecting = true
        let result = await Self.runCLI(path: cliPath, arguments: SlackAccountsDocument.args)
        isConnecting = false
        guard result.exitCode == 0 else {
            return .failure(RouteReadError("Could not read the Slack accounts: "
                + (result.stderr.isEmpty ? "exit \(result.exitCode)" : String(result.stderr.prefix(200)))))
        }
        do {
            let doc = try JSONDecoder().decode(SlackAccountsDocument.self, from: Data(result.stdout.utf8))
            return .success(SlackReloginRoute.route(accountID: accountID, in: doc))
        } catch {
            return .failure(RouteReadError("Could not read the Slack accounts: \(error.localizedDescription)"))
        }
    }

    /// Why the Re-login route could not be read, in the owner's words.
    struct RouteReadError: Error, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// The connect flow wrote an account: reload and re-wire the daemon, as
    /// a finished `slack login` does (onboarding defers the restart).
    func connectFlowWroteAccount(daemonPolicy: DaemonRestartPolicy) {
        applyResult((0, "", ""), failurePrefix: "", daemonPolicy: daemonPolicy)
    }

    func cancelConnect() {
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        authProcess = nil
        isConnecting = false
    }

    // MARK: - Enable / Disable

    /// Builds the CLI args to enable or disable `account` — `slack enable <id>`
    /// or `slack disable <id>`. Pure and side-effect-free.
    static func setEnabledArgs(for account: SlackAccount, enabled: Bool) -> [String] {
        ["slack", enabled ? "enable" : "disable", String(account.id)]
    }

    /// Enables or disables `account` via `watchtower slack enable|disable <id>`.
    /// A disabled account stops syncing but keeps all its already-synced data.
    func setEnabled(_ account: SlackAccount, enabled: Bool) async {
        await runManagementCommand(
            args: Self.setEnabledArgs(for: account, enabled: enabled),
            failurePrefix: enabled ? "Enable failed" : "Disable failed",
            daemonPolicy: .restart
        )
    }

    // MARK: - Rename

    /// Renames account `accountID` via `watchtower slack rename` (`AccountRename`). No
    /// daemon restart: the daemon reads labels when it needs them.
    func rename(accountID: Int, to name: String) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        error = await AccountRename.run(source: "slack", id: accountID, name: name, cliPath: cliPath())
        if error == nil { await refreshAsync() }
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `slack remove <id>`.
    /// Pure and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for account: SlackAccount) -> [String] {
        ["slack", "remove", String(account.id)]
    }

    /// Removes `account` via `watchtower slack remove <id>`: the CLI revokes
    /// the token at Slack, deletes the token file and marks the row
    /// removed/disabled. The synced data stays for now; with account data
    /// deletion on it is deleted 72 hours after Watchtower's next pass.
    func remove(_ account: SlackAccount, daemonPolicy: DaemonRestartPolicy = .restart) async {
        await runManagementCommand(
            args: Self.removeArgs(for: account),
            failurePrefix: "Remove failed",
            daemonPolicy: daemonPolicy
        )
    }

    // MARK: - Flow helpers

    /// Browser-consent flow (`add`/`login`) — holds the detached Process in
    /// `authProcess` so `cancelConnect()` can terminate it while this awaits.
    private func runAuthFlow(args: [String], failurePrefix: String, daemonPolicy: DaemonRestartPolicy) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isConnecting = true
        error = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        // The login environment is awaited with the flow already shown as
        // running (Cancel visible); a Cancel or a newer attempt meanwhile
        // drops this launch.
        process.environment = await loginEnvironment()
        guard authProcess === process else { return }

        let result = await Self.runProcess(process)
        authProcess = nil
        isConnecting = false
        applyResult(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
    }

    /// Non-browser management command (`enable`/`disable`/`remove`) — a plain
    /// awaited CLI invocation, no `authProcess` to cancel.
    private func runManagementCommand(
        args: [String],
        failurePrefix: String,
        daemonPolicy: DaemonRestartPolicy
    ) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isConnecting = true
        error = nil
        revokeNotice = nil

        let result = await Self.runCLI(path: cliPath, arguments: args)
        isConnecting = false
        if result.exitCode == 0 {
            // A remove whose revoke Slack did not confirm still exits 0; the
            // CLI logs the cause on stderr (`removeSlackAccount`).
            revokeNotice = SlackRevokeNotice.notice(inCLIOutput: result.stdout)
            CLILog.warning(args: args, stderr: result.stderr)
        }
        applyResult(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
    }

    private func applyResult(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        failurePrefix: String,
        daemonPolicy: DaemonRestartPolicy
    ) {
        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the account set change takes effect now
            // (unless onboarding defers it — `DaemonRestartPolicy`).
            daemonRestartTask = daemonPolicy.apply(using: daemon)
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
        process.environment = await Constants.resolvedEnvironmentAsync()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        return await runProcess(process)
    }

    /// Runs a pre-configured Process, draining stdout and stderr concurrently
    /// (`ProcessPipes`, SB3) so neither stream can wedge the other.
    nonisolated private static func runProcess(
        _ process: Process
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await ProcessPipes.run(process).trimmed
    }
}
