import Foundation
import GRDB
import WatchtowerCore

/// Drives the multi-account IMAP/Outlook email connections shown in
/// Settings → Email Accounts and the AddEmailAccountView sheet. Unlike Gmail
/// (a single OAuth token file owned by `GmailAuthService`), each row here is a
/// DB-backed `email_accounts` record — any number of IMAP mailboxes plus
/// Outlook OAuth accounts side by side. Owned by AppState so the accounts
/// list and any in-flight connect survive navigating away from Settings.
@MainActor
@Observable
final class EmailAccountsViewModel {
    private(set) var accounts: [EmailAccount] = []
    var isRunning = false
    var error: String?

    private let dbPool: DatabasePool
    private var authProcess: Process?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Refresh

    /// Cross-process writes (the CLI subprocess, or the daemon's IMAP/Outlook
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
            let rows = try await dbPool.read { db in try EmailAccountQueries.fetchAll(db) }
            self.accounts = rows
        } catch {
            self.error = "Failed to load accounts: \(error.localizedDescription)"
        }
    }

    // MARK: - Add IMAP

    /// Adds an IMAP mailbox via `watchtower imap add`. The password is NEVER
    /// passed as a flag/argv — it's written to the subprocess's stdin pipe
    /// (plus a trailing newline), then the pipe is closed. Returns true on
    /// success so the caller can dismiss the connect sheet.
    @discardableResult
    func addImapAccount(
        host: String,
        port: Int,
        username: String,
        password: String,
        folder: String,
        security: String,
        label: String
    ) async -> Bool {
        guard !isRunning else {
            error = "Another connection is already in progress."
            return false
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return false
        }

        isRunning = true
        error = nil

        let args = [
            "imap", "add",
            "--host", host,
            "--port", String(port),
            "--username", username,
            "--folder", folder,
            "--security", security,
            "--label", label
        ]

        let result = await Self.runCLI(path: cliPath, arguments: args, stdin: password + "\n")
        isRunning = false

        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the new mailbox's first sync + AI cycle runs now.
            Task { await DaemonManager.restart() }
            return true
        } else {
            error = result.stderr.isEmpty
                ? "Connect failed (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
            return false
        }
    }

    // MARK: - Outlook

    /// Runs `watchtower outlook login --app-return`, same OAuth loopback-browser
    /// flow shape as `GoogleAuthService.connect()`.
    func connectOutlook(label: String) {
        guard !isRunning else { return }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isRunning = true
        error = nil

        var args = ["outlook", "login", "--app-return"]
        if !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }

        // --app-return: the success page redirects to watchtower-auth:// so
        // macOS brings the app back to the foreground after the browser step.
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
                self.isRunning = false
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
                        ? "Login failed (exit \(result.exitCode))"
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
        isRunning = false
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `outlook logout <id>`
    /// for Outlook accounts, `imap remove <id>` for everything else (plain
    /// IMAP mailboxes). Pure and side-effect-free so the provider dispatch
    /// itself is directly testable without shelling out to a real process.
    static func removeArgs(for account: EmailAccount) -> [String] {
        account.isOutlook
            ? ["outlook", "logout", String(account.id)]
            : ["imap", "remove", String(account.id)]
    }

    /// Removes an account — `imap remove <id>` for IMAP mailboxes,
    /// `outlook logout <id>` for Outlook — dispatched by the account's own
    /// `provider` field.
    func remove(_ account: EmailAccount) async {
        guard !isRunning else {
            error = "Another connection is already in progress."
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }
        let args = Self.removeArgs(for: account)

        isRunning = true
        error = nil

        let result = await Self.runCLI(path: cliPath, arguments: args)
        isRunning = false

        if result.exitCode == 0 {
            error = nil
            refresh()
            // Restart so the daemon drops the removed account's syncer.
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
    /// already be a `Pipe` (see `runCLI` above) — the string is written to its
    /// `fileHandleForWriting` and the pipe is closed before draining output,
    /// which is how the IMAP password reaches the subprocess without ever
    /// touching argv.
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
