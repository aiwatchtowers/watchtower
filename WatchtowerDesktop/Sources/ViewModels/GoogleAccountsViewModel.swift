import Foundation
import GRDB

/// Drives the multi-account Google connections (Calendar and/or Gmail) shown
/// in Settings → Google Accounts and the add-account sheet. Each row is a
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
    var error: String?

    private let dbPool: DatabasePool
    private var authProcess: Process?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Refresh

    /// Cross-process writes (the CLI subprocess, or the daemon's Calendar/Gmail
    /// syncers) don't fire GRDB's ValueObservation, so callers reload on
    /// appear / after a CLI call completes rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `accounts` deterministically instead of racing a
    /// detached `Task`.
    func refreshAsync() async {
        do {
            let rows = try await dbPool.read { db in try GoogleAccountQueries.fetchAll(db) }
            self.accounts = rows
        } catch {
            self.error = "Failed to load accounts: \(error.localizedDescription)"
        }
    }

    // MARK: - Add

    /// Builds the `google add` args — always `--app-return` (the OAuth success
    /// page redirects to watchtower-auth:// so macOS brings the app back to
    /// the foreground), the selected services, an optional `--label`, and
    /// `--client-id`/`--client-secret-stdin` when the account brings its own
    /// Google Cloud OAuth client instead of Watchtower's build-time default.
    /// Pure and side-effect-free so the flag assembly is directly testable
    /// without shelling out to a real process.
    static func addArgs(label: String, calendar: Bool, gmail: Bool, hasCustomClient: Bool, clientID: String) -> [String] {
        var args = ["google", "add", "--app-return"]
        if calendar { args.append("--calendar") }
        if gmail { args.append("--gmail") }
        if !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }
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
    func addAccount(label: String, calendar: Bool, gmail: Bool, clientID: String, clientSecret: String) -> Bool {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return false
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return false
        }

        isConnecting = true
        error = nil

        let hasCustomClient = !clientID.isEmpty
        let args = Self.addArgs(label: label, calendar: calendar, gmail: gmail, hasCustomClient: hasCustomClient, clientID: clientID)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        if hasCustomClient {
            process.standardInput = Pipe()
        }
        authProcess = process

        Task.detached {
            let result = await Self.runProcess(process, stdin: hasCustomClient ? clientSecret + "\n" : nil)
            await MainActor.run {
                self.authProcess = nil
                self.isConnecting = false
                if result.exitCode == 0 {
                    self.error = nil
                    self.refresh()
                    // Re-wire the daemon so the new account's first sync runs now.
                    Task { await DaemonManager.restart() }
                } else if result.exitCode == 15 || result.exitCode == 9 {
                    // SIGTERM/SIGKILL — user cancelled
                    self.error = nil
                } else {
                    self.error = result.stderr.isEmpty
                        ? "Connect failed (exit \(result.exitCode))"
                        : String(result.stderr.prefix(200))
                }
            }
        }
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
    func relogin(_ account: GoogleAccount) {
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

        let args = Self.loginArgs(for: account)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        Task.detached {
            let result = await Self.runProcess(process)
            await MainActor.run {
                self.authProcess = nil
                self.isConnecting = false
                if result.exitCode == 0 {
                    self.error = nil
                    self.refresh()
                    Task { await DaemonManager.restart() }
                } else if result.exitCode == 15 || result.exitCode == 9 {
                    // SIGTERM/SIGKILL — user cancelled
                    self.error = nil
                } else {
                    self.error = result.stderr.isEmpty
                        ? "Re-login failed (exit \(result.exitCode))"
                        : String(result.stderr.prefix(200))
                }
            }
        }
    }

    func cancelConnect() {
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        authProcess = nil
        isConnecting = false
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `google remove <id>`.
    /// Pure and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for account: GoogleAccount) -> [String] {
        ["google", "remove", String(account.id)]
    }

    /// Removes `account` via `watchtower google remove <id>`.
    func remove(_ account: GoogleAccount) async {
        guard !isConnecting else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
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
            // Restart so the daemon drops the removed account's syncers.
            Task { await DaemonManager.restart() }
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
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        if stdin != nil {
            process.standardInput = Pipe()
        }
        return await runProcess(process, stdin: stdin)
    }

    /// Runs a pre-configured Process, reading pipe data before waitUntilExit to
    /// avoid deadlock. If `stdin` is provided, `process.standardInput` must
    /// already be a `Pipe` (see `runCLI`/`addAccount` above) — the string is
    /// written to its `fileHandleForWriting` and the pipe is closed before
    /// draining output, which is how the OAuth client secret reaches the
    /// subprocess without ever touching argv.
    nonisolated private static func runProcess(
        _ process: Process,
        stdin: String? = nil
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

        if let stdin, let inputPipe = process.standardInput as? Pipe {
            if let data = stdin.data(using: .utf8) {
                inputPipe.fileHandleForWriting.write(data)
            }
            inputPipe.fileHandleForWriting.closeFile()
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
