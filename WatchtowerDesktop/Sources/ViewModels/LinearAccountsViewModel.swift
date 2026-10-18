import Foundation
import WatchtowerCore

/// Drives Settings → Linear and the Add Linear sheet (shared with
/// onboarding's Connect step): the connected workspaces, connecting one by
/// OAuth (`linear add --app-return`, a browser consent like Jira's) or by a
/// personal API key (`linear add --api-key`, the key written to the CLI's
/// stdin, never argv), re-login, enable/disable/remove, and each workspace's
/// teams (`linear teams --json`, `teams select|deselect`). Owned by AppState
/// so an in-flight consent survives navigating away from Settings.
///
/// Accounts come from `linear accounts --json`, not the table: whether an
/// account signs in with OAuth or an API key lives in its token file.
@MainActor
@Observable
final class LinearAccountsViewModel {
    private(set) var accounts: [LinearAccount] = []
    /// Teams per account id, loaded on demand (`loadTeams`).
    private(set) var teams: [Int64: [LinearTeam]] = [:]
    /// Accounts whose team list failed to load, with the reason.
    private(set) var teamErrors: [Int64: String] = [:]
    var isBusy = false
    var error: String?

    /// The restart the last successful account change kicked off under
    /// `.restart` (nil under `.deferred`) — held so tests can await it.
    @ObservationIgnored private(set) var daemonRestartTask: Task<Void, Never>?
    /// Called after every successful reload. Injected by AppState, which
    /// re-reads the connected sources and the owner (OWNER-01).
    var onAccountsChanged: (() async -> Void)?

    private let daemon: any DaemonRestarting
    /// Resolves the CLI binary; injectable so tests can run a stand-in.
    private let cliPath: () -> String?
    private var authProcess: Process?

    init(daemon: any DaemonRestarting = LiveDaemonRestarter(), cliPath: @escaping () -> String? = Constants.findCLIPath) {
        self.daemon = daemon
        self.cliPath = cliPath
    }

    /// The live view model AppState holds: wired to `onAccountsChanged` and
    /// loading its list.
    static func started(onAccountsChanged: @escaping () async -> Void) -> LinearAccountsViewModel {
        let vm = LinearAccountsViewModel()
        vm.onAccountsChanged = onAccountsChanged
        vm.refresh()
        return vm
    }

    // MARK: - Arguments (pure)

    static let accountsArgs = ["linear", "accounts", "--json"]
    static let addOAuthArgs = ["linear", "add", "--app-return"]
    static let addAPIKeyArgs = ["linear", "add", "--api-key"]

    static func loginArgs(accountID: Int64, apiKey: Bool) -> [String] {
        ["linear", "login", "--account", String(accountID), apiKey ? "--api-key" : "--app-return"]
    }

    static func setEnabledArgs(accountID: Int64, enabled: Bool) -> [String] {
        ["linear", enabled ? "enable" : "disable", String(accountID)]
    }

    static func removeArgs(accountID: Int64) -> [String] {
        ["linear", "remove", String(accountID)]
    }

    static func teamsArgs(accountID: Int64) -> [String] {
        ["linear", "teams", "--json", "--account", String(accountID)]
    }

    static func selectTeamArgs(accountID: Int64, key: String, selected: Bool) -> [String] {
        ["linear", "teams", selected ? "select" : "deselect", "--account", String(accountID), key]
    }

    // MARK: - Refresh

    func refresh() {
        Task { await refreshAsync() }
    }

    /// Reloads the list from the CLI. A failure keeps the last list and says
    /// why; it never empties the list on a read error.
    func refreshAsync() async {
        guard let path = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        let result = await Self.run(path: path, arguments: Self.accountsArgs)
        guard result.exitCode == 0 else {
            error = Self.failure("Failed to load Linear workspaces", result)
            return
        }
        do {
            accounts = try LinearAccount.decodeList(Data(result.stdout.utf8))
            teams = teams.filter { id, _ in accounts.contains { $0.id == id } }
            await onAccountsChanged?()
        } catch {
            self.error = "Failed to read Linear workspaces: \(error.localizedDescription)"
        }
    }

    // MARK: - Connect

    /// Connects a workspace through Linear's browser consent. Cancel
    /// (`cancelConnect`) terminates the CLI mid-flow.
    func addWithOAuth(daemonPolicy: DaemonRestartPolicy = .restart) async {
        await runAuthFlow(args: Self.addOAuthArgs, failurePrefix: "Connect failed", daemonPolicy: daemonPolicy)
    }

    /// Re-consents an account in the browser (an OAuth account that went
    /// `revoked` or `error`).
    func relogin(_ account: LinearAccount) async {
        await runAuthFlow(
            args: Self.loginArgs(accountID: account.id, apiKey: false),
            failurePrefix: "Re-login failed", daemonPolicy: .restart)
    }

    /// Connects a workspace with a personal API key. The key goes to the
    /// CLI's stdin. Returns true on success so the sheet can close.
    @discardableResult
    func addWithAPIKey(_ key: String, daemonPolicy: DaemonRestartPolicy = .restart) async -> Bool {
        await runKeyCommand(args: Self.addAPIKeyArgs, key: key, failurePrefix: "Connect failed", daemonPolicy: daemonPolicy)
    }

    /// Replaces an account's API key (`linear login --api-key`).
    @discardableResult
    func reloginWithAPIKey(_ account: LinearAccount, key: String) async -> Bool {
        await runKeyCommand(
            args: Self.loginArgs(accountID: account.id, apiKey: true), key: key,
            failurePrefix: "Re-login failed", daemonPolicy: .restart)
    }

    func cancelConnect() {
        if let process = authProcess, process.isRunning { process.terminate() }
        authProcess = nil
        isBusy = false
    }

    // MARK: - Manage

    /// A disabled workspace stops syncing and keeps its synced issues.
    func setEnabled(_ account: LinearAccount, enabled: Bool) async {
        await runManagement(
            args: Self.setEnabledArgs(accountID: account.id, enabled: enabled),
            failurePrefix: enabled ? "Enable failed" : "Disable failed", daemonPolicy: .restart)
    }

    /// Non-destructive: the CLI revokes (OAuth) and deletes the token and
    /// marks the row removed; synced issues stay.
    func remove(_ account: LinearAccount, daemonPolicy: DaemonRestartPolicy = .restart) async {
        await runManagement(args: Self.removeArgs(accountID: account.id), failurePrefix: "Remove failed", daemonPolicy: daemonPolicy)
    }

    // MARK: - Teams

    /// Loads an account's teams. The list is empty until the workspace's
    /// first sync has fetched them.
    func loadTeams(for account: LinearAccount) async {
        guard let path = cliPath() else {
            teamErrors[account.id] = "Watchtower CLI not found"
            return
        }
        let result = await Self.run(path: path, arguments: Self.teamsArgs(accountID: account.id))
        guard result.exitCode == 0 else {
            teamErrors[account.id] = Self.failure("Couldn't load teams", result)
            return
        }
        do {
            teams[account.id] = try LinearTeam.decodeList(Data(result.stdout.utf8))
            teamErrors[account.id] = nil
        } catch {
            teamErrors[account.id] = "Couldn't read teams: \(error.localizedDescription)"
        }
    }

    /// Selects or deselects one team for sync, then reloads the account's
    /// teams so the list shows what the CLI stored. The daemon reads the
    /// selection on its next pass, so no restart.
    func setTeam(_ team: LinearTeam, selected: Bool, for account: LinearAccount) async {
        guard !isBusy else {
            error = "Another connection is already in progress."
            return
        }
        guard let path = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isBusy = true
        error = nil
        let result = await Self.run(
            path: path, arguments: Self.selectTeamArgs(accountID: account.id, key: team.key, selected: selected))
        isBusy = false
        if result.exitCode != 0 {
            error = Self.failure(selected ? "Selecting \(team.key) failed" : "Deselecting \(team.key) failed", result)
        }
        await loadTeams(for: account)
    }

    // MARK: - Flow helpers

    private func runAuthFlow(args: [String], failurePrefix: String, daemonPolicy: DaemonRestartPolicy) async {
        guard !isBusy else {
            error = "Another connection is already in progress."
            return
        }
        guard let path = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isBusy = true
        error = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process
        process.environment = await Constants.resolvedEnvironmentAsync()
        // A Cancel while the environment resolved drops this launch.
        guard authProcess === process else { return }
        let onLaunch: @Sendable (Process) -> Void = { [weak self] launched in
            Task { @MainActor in
                if self?.authProcess !== launched { launched.terminate() }
            }
        }
        let result = await ProcessPipes.run(process, onLaunch: onLaunch).trimmed
        guard authProcess === process else {
            // Cancelled, but the CLI may have connected before the Cancel
            // landed: wire that change in.
            if result.exitCode == 0 { await applySuccess(daemonPolicy) }
            return
        }
        authProcess = nil
        isBusy = false
        await apply(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
    }

    private func runKeyCommand(
        args: [String], key: String, failurePrefix: String, daemonPolicy: DaemonRestartPolicy
    ) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            error = "Paste a Linear API key."
            return false
        }
        guard !isBusy else {
            error = "Another connection is already in progress."
            return false
        }
        guard let path = cliPath() else {
            error = "Watchtower CLI not found"
            return false
        }
        isBusy = true
        error = nil
        let result = await Self.run(path: path, arguments: args, stdin: trimmed + "\n")
        isBusy = false
        await apply(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
        return result.exitCode == 0
    }

    private func runManagement(args: [String], failurePrefix: String, daemonPolicy: DaemonRestartPolicy) async {
        guard !isBusy else {
            error = "Another connection is already in progress."
            return
        }
        guard let path = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        isBusy = true
        error = nil
        let result = await Self.run(path: path, arguments: args)
        isBusy = false
        await apply(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
    }

    private func apply(
        _ result: (exitCode: Int32, stdout: String, stderr: String), failurePrefix: String, daemonPolicy: DaemonRestartPolicy
    ) async {
        switch result.exitCode {
        case 0:
            await applySuccess(daemonPolicy)
        case 15, 9:
            // SIGTERM/SIGKILL: the owner cancelled.
            error = nil
        default:
            error = Self.failure(failurePrefix, result)
        }
    }

    /// The daemon builds its Linear syncers at start, so an account change
    /// takes effect with a restart (unless onboarding defers it).
    private func applySuccess(_ daemonPolicy: DaemonRestartPolicy) async {
        error = nil
        await refreshAsync()
        daemonRestartTask = daemonPolicy.apply(using: daemon)
    }

    private static func failure(_ prefix: String, _ result: (exitCode: Int32, stdout: String, stderr: String)) -> String {
        result.stderr.isEmpty ? "\(prefix) (exit \(result.exitCode))" : String(result.stderr.prefix(200))
    }

    nonisolated private static func run(
        path: String, arguments: [String], stdin: String? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = await Constants.resolvedEnvironmentAsync()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        if stdin != nil { process.standardInput = Pipe() }
        return await ProcessPipes.run(process, stdin: stdin).trimmed
    }
}
