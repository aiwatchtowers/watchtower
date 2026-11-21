import Foundation
import GRDB
import WatchtowerCore

/// Drives the multi-account Google connections (Calendar and/or Gmail) shown
/// in Connections → Google Accounts and the add-account sheet. Each row is a
/// DB-backed `google_accounts` record — any number of Google accounts side by
/// side, each independently granting Calendar and/or Gmail access via its own
/// OAuth consent flow. Owned by AppState so the accounts list and any
/// in-flight connect survive navigating away from Settings. Deliberate
/// structural copy of `EmailAccountsViewModel`/`CalendarAccountsViewModel`
/// (house pattern), with the Outlook-style detached-Process OAuth flow from
/// `EmailAccountsViewModel.connectOutlook` since `google add`/`google login`
/// are both browser-consent flows like `outlook login`.
@MainActor
@Observable
final class GoogleAccountsViewModel {
    private(set) var accounts: [GoogleAccount] = []
    var isConnecting = false
    /// Where a browser sign-in waits for the owner (`SignInWaitLine`): the
    /// detail's add section (a new account, or Calendar's legacy re-login)
    /// or one account's row. Nil while none runs — `isConnecting` alone
    /// also covers a remove.
    enum SignInPlace: Equatable {
        case section
        case account(Int)
    }
    private(set) var signIn: SignInPlace?
    /// The account whose row waits; nil for a section-level (or legacy) sign-in.
    var signInAccountID: Int? {
        if case .account(let id) = signIn { id } else { nil }
    }
    var error: String? {
        // Any newer error (or none) is no longer that sign-in's.
        didSet { failedSignIn = nil }
    }
    /// Where the sign-in whose failure `error` holds was waiting, so a place
    /// with no row or banner of its own (Calendar's top line) can say why.
    private(set) var failedSignIn: SignInPlace?
    /// The last account read failed (the error's own text); nil once one
    /// succeeds. Only the read: an action's failure stays in `error` (the
    /// Connections tab's "Couldn't read accounts" reads this).
    private(set) var readError: String?
    /// A first account read finished, well or not: before it the detail
    /// shows its loading line, never "nothing connected".
    private(set) var hasRead = false
    /// Accounts Go reports on the retiring shared app (#1887 §7 banners).
    let sharedFlags = SharedAppFlagReader.google()
    /// Every successful refresh also reads the shared-app flags; on in the
    /// app, off by default so a test never runs a real CLI.
    @ObservationIgnored var readsAccountFlags: Bool

    /// The restart the last successful account change kicked off under
    /// `.restart` (nil under `.deferred`) — held so tests can await it.
    @ObservationIgnored private(set) var daemonRestartTask: Task<Void, Never>?
    /// The in-flight browser sign-in (`addAccount`, `relogin`,
    /// `reloginLegacyCalendar`) — held so tests can await the
    /// fire-and-forget flow.
    @ObservationIgnored private(set) var signInTask: Task<Void, Never>?

    private let dbPool: DatabasePool
    private let daemon: any DaemonRestarting
    /// Resolves the CLI binary; injectable so tests can run a stand-in.
    private let cliPath: () -> String?
    private var authProcess: Process?
    /// The sign-in child's environment; injectable so tests can hold it.
    @ObservationIgnored var loginEnvironment: @Sendable () async -> [String: String] = {
        await Constants.resolvedEnvironmentAsync()
    }
    /// Runs between the launch check and the launch; a test holds it to land
    /// a Cancel in that window.
    @ObservationIgnored var beforeLaunch: @Sendable () async -> Void = {}

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

    /// Cross-process writes (the CLI subprocess, or the daemon's Calendar/Gmail
    /// syncers) don't fire GRDB's ValueObservation, so callers reload on
    /// appear / after a CLI call completes rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `accounts` deterministically instead of racing a
    /// detached `Task`.
    ///
    /// `quiet` (the re-read after a Cancel) reports a failed read through
    /// `readError` only, never `error`: a Cancel stays silent, and a newer
    /// attempt's result is never overwritten.
    func refreshAsync(quiet: Bool = false) async {
        do {
            let rows = try await dbPool.read { db in try GoogleAccountQueries.fetchAll(db) }
            self.accounts = rows
            readError = nil
            hasRead = true
            await onAccountsChanged?()
        } catch {
            if !quiet { self.error = "Failed to load accounts: \(error.localizedDescription)" }
            readError = error.localizedDescription
            hasRead = true
            return
        }
        if readsAccountFlags { await sharedFlags.read(cliPath: cliPath()) }
    }

    // MARK: - Add

    /// Builds the `google add` args — always `--app-return` (the CLI opens
    /// watchtower-auth:// once consent is done, so macOS brings the app back
    /// to the foreground), the selected services, and
    /// `--client-id`/`--client-secret-stdin` when the account brings its own
    /// Google Cloud OAuth client instead of Watchtower's build-time default.
    /// No `--label`: the CLI names the account after its mail domain
    /// (`db.MailAccountLabel`); the owner renames it in Settings.
    /// Pure and side-effect-free so the flag assembly is directly testable
    /// without shelling out to a real process.
    static func addArgs(calendar: Bool, gmail: Bool, hasCustomClient: Bool, clientID: String) -> [String] {
        var args = ["google", "add", "--app-return"]
        if calendar { args.append("--calendar") }
        if gmail { args.append("--gmail") }
        if hasCustomClient {
            args.append(contentsOf: ["--client-id", clientID, "--client-secret-stdin"])
        }
        return args
    }

    /// Connects a new Google account via `watchtower google add --app-return`.
    /// A non-empty `clientID` brings the account's own OAuth client; the
    /// matching `clientSecret` is NEVER passed as a flag/argv — it's written
    /// to the subprocess's stdin pipe (plus a trailing newline), same as the
    /// IMAP password / CalDAV credential pattern.
    ///
    /// Returns whether a connect attempt actually started — `false` from
    /// either early-return guard below means `isConnecting` never flips
    /// true→false for THIS call, so a caller gating on that transition (e.g.
    /// `AddGoogleAccountView`'s auto-dismiss-on-success `onChange`) must not
    /// arm itself when this returns `false`.
    @discardableResult
    func addAccount(
        calendar: Bool,
        gmail: Bool,
        clientID: String,
        clientSecret: String,
        daemonPolicy: DaemonRestartPolicy = .restart
    ) -> Bool {
        guard !isConnecting else {
            error = Self.busyMessage
            return false
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return false
        }

        let hasCustomClient = !clientID.isEmpty
        let process = Process()
        process.arguments = Self.addArgs(calendar: calendar, gmail: gmail, hasCustomClient: hasCustomClient, clientID: clientID)
        if hasCustomClient {
            process.standardInput = Pipe()
        }
        startSignIn(process, cliPath: cliPath, place: .section, stdin: hasCustomClient ? clientSecret + "\n" : nil,
                    failure: "Connect failed", daemonPolicy: daemonPolicy)
        return true
    }

    // MARK: - Re-login

    /// Builds the `google login` args for re-consenting an existing account —
    /// its currently granted services are re-requested as-is so the OAuth
    /// screen matches what's already connected. Pure and side-effect-free.
    static func loginArgs(for account: GoogleAccount) -> [String] {
        var args = ["google", "login", "--account", String(account.id), "--app-return"]
        if account.calendarEnabled { args.append("--calendar") }
        if account.gmailEnabled { args.append("--gmail") }
        return args
    }

    /// Re-consents `account` via `watchtower google login --account <id>
    /// --app-return` — same OAuth loopback-browser flow shape as `addAccount`,
    /// used when an account's status is "error"/"revoked" and needs a fresh
    /// grant.
    func relogin(_ account: GoogleAccount, daemonPolicy: DaemonRestartPolicy = .restart) {
        relogin(args: Self.loginArgs(for: account), accountID: account.id, daemonPolicy: daemonPolicy)
    }

    /// Re-consents account `accountID` that no successful read has listed
    /// yet (Calendar's revoked alert before the first read, or after a failed
    /// one): `google login --account <id> --app-return` with no service
    /// flags, so the CLI re-requests what the account already granted.
    func relogin(accountID: Int, daemonPolicy: DaemonRestartPolicy = .restart) {
        relogin(args: ["google", "login", "--account", String(accountID), "--app-return"], accountID: accountID,
                daemonPolicy: daemonPolicy)
    }

    private func relogin(args: [String], accountID: Int, daemonPolicy: DaemonRestartPolicy) {
        guard !isConnecting else {
            error = Self.busyMessage
            return
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        let process = Process()
        process.arguments = args
        startSignIn(process, cliPath: cliPath, place: .account(accountID), failure: "Re-login failed",
                    daemonPolicy: daemonPolicy)
    }

    /// Another Google sign-in or command runs.
    static let busyMessage = "Another connection is already in progress."

    /// The `calendar login` args of the revoked-calendar alert when it names
    /// no account that exists: the CLI resolves account #1 itself.
    static let legacyCalendarLoginArgs = ["calendar", "login", "--app-return"]

    /// The revoked-calendar alert's Reconnect with no account to point at
    /// (`AppState.reconnectGoogleCalendar`): today's `calendar login
    /// --app-return`, under this model's one Google busy flag so it never
    /// runs beside another Google sign-in and offers the same Cancel.
    func reloginLegacyCalendar(daemonPolicy: DaemonRestartPolicy = .restart) {
        guard !isConnecting else {
            error = Self.busyMessage
            return
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        let process = Process()
        process.arguments = Self.legacyCalendarLoginArgs
        startSignIn(process, cliPath: cliPath, place: .section, failure: "Login failed", daemonPolicy: daemonPolicy)
    }

    /// Runs one browser sign-in. Cancel (`cancelConnect`) and the run's
    /// completion both end it; the completion writes only while its process
    /// is still the current one, so a cancelled run's late exit never resets
    /// an attempt started after it.
    private func startSignIn(
        _ process: Process,
        cliPath: String,
        place: SignInPlace,
        stdin: String? = nil,
        failure: String,
        daemonPolicy: DaemonRestartPolicy
    ) {
        isConnecting = true
        signIn = place
        error = nil
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        let environment = loginEnvironment
        let beforeLaunch = beforeLaunch
        signInTask = Task.detached {
            // The login environment is awaited here, off the main actor; a
            // Cancel (or a newer attempt) while it resolves drops this launch.
            process.environment = await environment()
            guard await MainActor.run(body: { self.authProcess === process }) else { return }
            await beforeLaunch()
            // A Cancel that landed while the launch was under way found
            // nothing running to terminate: stop the child once it exists.
            let onLaunch: @Sendable (Process) -> Void = { launched in
                Task { @MainActor in
                    if self.authProcess !== launched { launched.terminate() }
                }
            }
            let result = await ProcessPipes.run(process, stdin: stdin, onLaunch: onLaunch).trimmed
            await self.finishSignIn(process, place: place, result: result, failure: failure, daemonPolicy: daemonPolicy)
        }
    }

    /// The end of a sign-in run. Cancelled or superseded, it leaves the
    /// state to Cancel and the newer run: a CLI that had already exited 0
    /// is a finished connect (re-read and the daemon policy); one killed,
    /// maybe part-way through saving, gets a quiet re-read so whatever
    /// landed shows — a half-saved account as one that needs Re-login.
    private func finishSignIn(
        _ process: Process,
        place: SignInPlace,
        result: (exitCode: Int32, stdout: String, stderr: String),
        failure: String,
        daemonPolicy: DaemonRestartPolicy
    ) async {
        guard authProcess === process else {
            if result.exitCode == 0 {
                // Quiet while a newer run is active: its result is never overwritten.
                await refreshAsync(quiet: isConnecting)
                daemonRestartTask = daemonPolicy.apply(using: daemon)
            } else {
                await refreshAsync(quiet: true)
            }
            return
        }
        authProcess = nil
        isConnecting = false
        signIn = nil
        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the account's first sync runs now
            // (unless onboarding defers it — `DaemonRestartPolicy`).
            daemonRestartTask = daemonPolicy.apply(using: daemon)
        } else if result.exitCode == 15 || result.exitCode == 9 {
            // SIGTERM/SIGKILL from outside the app — no failure to show.
            error = nil
        } else {
            error = result.stderr.isEmpty
                ? "\(failure) (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
            failedSignIn = place
        }
    }

    /// Another flow's `google add` connected an account (Use my own Google
    /// project, #1887 C4): re-read the accounts and re-wire the daemon, as
    /// this model's own connect does.
    func accountAddedElsewhere(daemonPolicy: DaemonRestartPolicy) {
        refresh()
        daemonRestartTask = daemonPolicy.apply(using: daemon)
    }

    /// Cancel of a waiting sign-in: silent (no error), the state resets at
    /// once; the killed run's end only re-reads the accounts
    /// (`finishSignIn`), never restarts the daemon.
    func cancelConnect() {
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        authProcess = nil
        isConnecting = false
        signIn = nil
    }

    // MARK: - Rename

    /// Renames account `accountID` via `watchtower google rename` (`AccountRename`). No
    /// daemon restart: the daemon reads labels when it needs them.
    func rename(accountID: Int, to name: String) async {
        guard !isConnecting else {
            error = Self.busyMessage
            return
        }
        error = await AccountRename.run(source: "google", id: accountID, name: name, cliPath: cliPath())
        if error == nil { await refreshAsync() }
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `google remove <id>`.
    /// Pure and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for account: GoogleAccount) -> [String] {
        ["google", "remove", String(account.id)]
    }

    /// Removes `account` via `watchtower google remove <id>`.
    func remove(_ account: GoogleAccount, daemonPolicy: DaemonRestartPolicy = .restart) async {
        guard !isConnecting else {
            error = Self.busyMessage
            return
        }
        guard let cliPath = cliPath() else {
            error = "Watchtower CLI not found"
            return
        }
        let args = Self.removeArgs(for: account)

        isConnecting = true
        error = nil

        let result = await Self.runCLI(path: cliPath, arguments: args)
        isConnecting = false

        if result.exitCode == 0 {
            error = nil
            refresh()
            // Restart so the daemon drops the removed account's syncers
            // (unless onboarding defers it — `DaemonRestartPolicy`).
            daemonRestartTask = daemonPolicy.apply(using: daemon)
        } else {
            error = result.stderr.isEmpty
                ? "Remove failed (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
        }
    }

    // MARK: - CLI Helpers

    nonisolated private static func runCLI(
        path: String,
        arguments: [String],
        stdin: String? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = await Constants.resolvedEnvironmentAsync()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        if stdin != nil {
            process.standardInput = Pipe()
        }
        return await runProcess(process, stdin: stdin)
    }

    /// Runs a pre-configured Process, draining stdout and stderr concurrently
    /// (`ProcessPipes`, SB3). If `stdin` is provided, `process.standardInput` must
    /// already be a `Pipe` (see `runCLI`/`addAccount` above) — the string is
    /// written to its `fileHandleForWriting` and the pipe is closed before
    /// draining output, which is how the OAuth client secret reaches the
    /// subprocess without ever touching argv.
    nonisolated private static func runProcess(
        _ process: Process,
        stdin: String? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await ProcessPipes.run(process, stdin: stdin).trimmed
    }
}
