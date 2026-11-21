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
    /// The account whose browser sign-in (`slack login`) is waiting; nil
    /// when none is, or the waiting one is a new workspace (`slack add`).
    /// Its row shows the waiting line with Cancel in place of Re-login.
    private(set) var signInAccountID: Int?
    /// Test seams: the Re-login route's `slack accounts --json` read, and a
    /// hold between the sign-in child's exit and its completion.
    @ObservationIgnored var routeDocumentRead: (() async -> Result<SlackAccountsDocument, RouteReadError>)?
    @ObservationIgnored var afterAuthExit: (() async -> Void)?
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
        cliPath: @escaping () -> String? = Constants.findCLIPath,
        readsAccountFlags: Bool = false
    ) {
        self.dbPool = dbPool
        self.daemon = daemon
        self.cliPath = cliPath
        self.readsAccountFlags = readsAccountFlags
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
    /// `quiet`: a re-read for a cancelled attempt — a failure lands in
    /// `readError` only, so the Cancel stays silent and a newer attempt's
    /// `error` is never overwritten.
    func refreshAsync(quiet: Bool = false) async {
        do {
            let (rows, syncs) = try await dbPool.read { db in
                (try SlackAccountQueries.fetchAll(db), try SlackAccountQueries.fetchLastSyncs(db))
            }
            self.accounts = rows
            lastSyncs = syncs
            readError = nil
            await onAccountsChanged?()
        } catch {
            let message = "Failed to load accounts: \(error.localizedDescription)"
            if !quiet { self.error = message }
            readError = message
        }
        if readsAccountFlags { await refreshFlags() }
    }

    // MARK: - Flags from `slack accounts --json` (plan B Task 15)

    /// Each account's newest successful channel sync, for the shared-app line.
    private(set) var lastSyncs: [Int: Date] = [:]
    /// The last `slack accounts --json` read that succeeded: Go's verdict on
    /// the shared app, each account's Re-login route and whether the build
    /// has its own Slack app. nil until one succeeds; a failed read keeps it.
    private(set) var accountFlags: SlackAccountsDocument?
    /// Every refresh also reads the flags; on in the app, off by default so a
    /// test never runs a real CLI.
    @ObservationIgnored var readsAccountFlags: Bool
    /// Reads finish out of order: only a newer read's answer replaces the flags.
    @ObservationIgnored private var flagReads = 0
    @ObservationIgnored private var appliedFlagRead = 0

    /// Accounts Go reports on the retired shared app (`shared_app`); empty
    /// before the first successful read, so no banner on a failed one.
    var sharedAppAccountIDs: Set<Int> {
        Set(accountFlags?.accounts.filter(\.sharedApp).map { Int($0.id) } ?? [])
    }

    /// `builtin_app`: the build has a Slack app of its own. Before the first
    /// successful read it counts as true, the build's behaviour before plan B
    /// (Add Slack Workspace, the Add sheet in onboarding).
    var builtinApp: Bool { accountFlags?.builtinApp ?? true }

    /// Account `id`'s Re-login route ("builtin" | "connect" | "move"); nil
    /// when not read.
    func relogin(of id: Int) -> String? {
        accountFlags?.accounts.first { $0.id == Int64(id) }?.relogin
    }

    /// Reads `slack accounts --json` and keeps its answer; a failure keeps
    /// the last flags (logged, never shown: the pane works without them).
    func refreshFlags() async {
        flagReads += 1
        let read = flagReads
        switch await readAccountsDocument() {
        case let .success(doc):
            applyFlags(doc, read: read)
        case let .failure(failure):
            CLILog.warning(args: SlackAccountsDocument.args, stderr: failure.message)
        }
    }

    private func applyFlags(_ doc: SlackAccountsDocument, read: Int) {
        guard read > appliedFlagRead else { return }
        appliedFlagRead = read
        accountFlags = doc
    }

    private func readAccountsDocument() async -> Result<SlackAccountsDocument, RouteReadError> {
        guard let cliPath = cliPath() else { return .failure(RouteReadError("Watchtower CLI not found")) }
        let result = await Self.runCLI(path: cliPath, arguments: SlackAccountsDocument.args)
        guard result.exitCode == 0 else {
            return .failure(RouteReadError("Could not read the Slack accounts: "
                + (result.stderr.isEmpty ? "exit \(result.exitCode)" : String(result.stderr.prefix(200)))))
        }
        do {
            return .success(try JSONDecoder().decode(SlackAccountsDocument.self, from: Data(result.stdout.utf8)))
        } catch {
            return .failure(RouteReadError("Could not read the Slack accounts: \(error.localizedDescription)"))
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
    @discardableResult
    func addAccount(daemonPolicy: DaemonRestartPolicy = .restart) async -> SignInOutcome {
        guard let mine = beginAttempt(accountID: nil) else { return .failed(error ?? "") }
        return await runAuthFlow(mine, args: Self.addArgs, failurePrefix: "Connect failed", daemonPolicy: daemonPolicy)
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

    /// How one sign-in attempt ended, as its own caller sees it — never read
    /// off the VM's shared state, which a newer attempt may own by then.
    enum SignInOutcome: Equatable {
        /// The built-in sign-in ran to its end.
        case signedIn
        /// The sign-in continues on the connect flow (`.flow`) or its connect
        /// section (`.connectSection`).
        case handedOff(SlackReloginRoute)
        /// The owner cancelled it; nothing to show.
        case cancelled
        /// Nothing started, or the sign-in failed: why (also in `error`).
        case failed(String)
    }

    /// Re-consents `account` by its route in `slack accounts --json` (plan B
    /// A7): the build's own app re-runs `watchtower slack login --account <id>
    /// --app-return`; a workspace app goes through the connect flow on the
    /// Desktop's running listener (a `slack login` would bind 18551, which
    /// that listener holds); no app to sign in with opens the connect section.
    /// The attempt is cancellable from its start, the route read included.
    /// `forCard`: an agent card's Reconnect Slack, which `cancelCardSignIn`
    /// ends.
    @discardableResult
    func relogin(_ account: SlackAccount, forCard: Bool = false) async -> SignInOutcome {
        guard let mine = beginAttempt(accountID: account.id) else { return .failed(error ?? "") }
        if forCard { cardAttempts[account.id] = mine }
        defer { if cardAttempts[account.id] == mine { cardAttempts[account.id] = nil } }
        let loginArgs = Self.loginArgs(for: account)
        guard let flow = connectFlow else {
            return await runAuthFlow(mine, args: loginArgs, failurePrefix: "Re-login failed", daemonPolicy: .restart)
        }
        let read = await readRoute(accountID: Int64(account.id))
        guard isCurrent(mine) else { return await cancelledAttemptEnded() }
        let route: SlackReloginRoute
        switch read {
        case let .failure(failure):
            return failAttempt(failure.message)
        case let .success(found):
            route = found
        }
        guard route == .builtin else {
            endAttempt()
            guard flow.reconnect(route) else { return failAttempt("Another connection is already in progress.") }
            error = nil // handed off: an earlier failure no longer applies
            return .handedOff(route)
        }
        // One flow at a time: the built-in sign-in waits for the connect flow
        // and a company chain (#1887) too.
        guard !flow.isRunning, !flow.companyRunning() else {
            return failAttempt("Another connection is already in progress.")
        }
        return await runAuthFlow(mine, args: loginArgs, failurePrefix: "Re-login failed", daemonPolicy: .restart)
    }

    private func failAttempt(_ message: String) -> SignInOutcome {
        endAttempt()
        error = message
        return .failed(message)
    }

    /// The route of account `accountID` from `slack accounts --json`, or why
    /// it could not be read. Shown as connecting while it reads, so no other
    /// sign-in starts meanwhile; leaves `error` to the caller.
    func reloginRoute(accountID: Int64) async -> Result<SlackReloginRoute, RouteReadError> {
        guard !isConnecting else { return .failure(RouteReadError("Another connection is already in progress.")) }
        isConnecting = true
        let result = await readRoute(accountID: accountID)
        isConnecting = false
        return result
    }

    /// Reads account `accountID`'s route; the read is the freshest answer, so
    /// the row's button follows it.
    private func readRoute(accountID: Int64) async -> Result<SlackReloginRoute, RouteReadError> {
        flagReads += 1
        let read = flagReads
        let result: Result<SlackAccountsDocument, RouteReadError>
        if let routeDocumentRead { result = await routeDocumentRead() } else { result = await readAccountsDocument() }
        if case let .success(doc) = result { applyFlags(doc, read: read) }
        return result.map { SlackReloginRoute.route(accountID: accountID, in: $0) }
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

    /// Browser-consent flow (`add`/`login`) of attempt `mine`, already
    /// begun (`beginAttempt`): holds the detached Process in `authProcess`
    /// so a Cancel can terminate it while this awaits.
    ///
    /// An attempt a Cancel ended is no longer current: its state was reset by
    /// the Cancel and a newer attempt may own it, so it touches nothing but a
    /// refresh-only re-read of the accounts (whatever the CLI saved before it
    /// was killed shows) — except an account change that finished before the
    /// Cancel landed, wired in like a finished one (the Jira precedent).
    private func runAuthFlow(
        _ mine: Int, args: [String], failurePrefix: String, daemonPolicy: DaemonRestartPolicy
    ) async -> SignInOutcome {
        guard let cliPath = cliPath() else {
            endAttempt()
            error = "Watchtower CLI not found"
            return .failed("Watchtower CLI not found")
        }
        signInAccountID = attempt?.accountID
        error = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        // The login environment is awaited with the flow already shown as
        // running (Cancel visible); a Cancel meanwhile drops this launch.
        process.environment = await loginEnvironment()
        guard isCurrent(mine) else { return await cancelledAttemptEnded() }

        // A Cancel that landed while the launch was under way found nothing
        // running to terminate: stop the child as soon as it exists.
        let onLaunch: @Sendable (Process) -> Void = { [weak self] launched in
            Task { @MainActor in
                if self?.isCurrent(mine) != true { launched.terminate() }
            }
        }
        let result = await ProcessPipes.run(process, onLaunch: onLaunch).trimmed
        await afterAuthExit?()
        guard isCurrent(mine) else {
            guard result.exitCode == 0 else { return await cancelledAttemptEnded() }
            await refreshAsync(quiet: true)
            daemonRestartTask = daemonPolicy.apply(using: daemon)
            return .signedIn
        }
        endAttempt()
        applyResult(result, failurePrefix: failurePrefix, daemonPolicy: daemonPolicy)
        switch result.exitCode {
        case 0: return .signedIn
        case 15, 9: return .cancelled // SIGTERM/SIGKILL from outside: no error shown
        default: return .failed(error ?? "\(failurePrefix) (exit \(result.exitCode))")
        }
    }

    // MARK: - Sign-in attempts

    /// One sign-in (`addAccount`, `relogin`) from its start to its end: what
    /// a Cancel ends. `accountID` is the account a Re-login re-consents.
    private struct Attempt {
        let id: Int
        let accountID: Int?
    }

    @ObservationIgnored private var attempt: Attempt?
    @ObservationIgnored private var attempts = 0

    /// Starts an attempt and marks the VM connecting; nil (with `error` set)
    /// when another command runs.
    private func beginAttempt(accountID: Int?) -> Int? {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return nil
        }
        attempts += 1
        attempt = Attempt(id: attempts, accountID: accountID)
        isConnecting = true
        return attempts
    }

    private func isCurrent(_ mine: Int) -> Bool {
        attempt?.id == mine
    }

    /// The current attempt ended: the VM is idle again.
    private func endAttempt() {
        attempt = nil
        authProcess = nil
        isConnecting = false
        signInAccountID = nil
    }

    /// The end of an attempt a Cancel ended: a refresh-only re-read of the
    /// accounts, never a daemon restart.
    private func cancelledAttemptEnded() async -> SignInOutcome {
        await refreshAsync(quiet: true)
        return .cancelled
    }

    /// Ends the current sign-in attempt at once and silently: the busy state
    /// resets here, no error is set, and the attempt's own completion, no
    /// longer current, only re-reads the accounts. Nothing to cancel (no
    /// attempt, or a management command running) leaves the state as it is.
    func cancelConnect() {
        guard attempt != nil else { return }
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        endAttempt()
    }

    /// Cancels the attempt re-consenting account `accountID` only (its
    /// Connections row's Cancel); another Slack sign-in keeps running.
    func cancelConnect(accountID: Int) {
        guard attempt?.accountID == accountID else { return }
        cancelConnect()
    }

    /// The attempt an agent card began for each account (`relogin(_:forCard:)`),
    /// while it runs.
    @ObservationIgnored private var cardAttempts: [Int: Int] = [:]

    /// An agent card's Cancel: ends the attempt that card began for
    /// `accountID`, once — never a Re-login started elsewhere, even of the
    /// same account after the card's own was cancelled.
    func cancelCardSignIn(accountID: Int) {
        guard let mine = cardAttempts.removeValue(forKey: accountID), isCurrent(mine) else { return }
        cancelConnect()
    }

    /// The waiting line's texts for account `id`'s row; nil when its
    /// sign-in is not the one waiting.
    func signInWait(forAccount id: Int) -> SignInWaitCopy? {
        signInAccountID == id ? .slack : nil
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
