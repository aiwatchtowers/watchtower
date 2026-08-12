import Foundation
import GRDB
import WatchtowerCore

/// Drives the multi-account CalDAV/ICS calendar connections shown in
/// Settings → Calendar Accounts and the AddCalendarAccountView sheet. Unlike
/// Google Calendar (a single OAuth token file owned by `GoogleAuthService`),
/// each row here is a DB-backed `calendar_accounts` record — any number of
/// CalDAV servers plus secret ICS feeds side by side. Owned by AppState so the
/// accounts list and any in-flight connect survive navigating away from
/// Settings. Deliberate structural copy of `EmailAccountsViewModel` (house
/// pattern).
@MainActor
@Observable
final class CalendarAccountsViewModel {
    private(set) var accounts: [CalendarAccount] = []
    var isRunning = false
    var error: String?

    private let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Refresh

    /// Cross-process writes (the CLI subprocess, or the daemon's CalDAV/ICS
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
            let rows = try await dbPool.read { db in try CalendarAccountQueries.fetchAll(db) }
            self.accounts = rows
        } catch {
            self.error = "Failed to load accounts: \(error.localizedDescription)"
        }
    }

    // MARK: - Add CalDAV

    /// Adds a CalDAV calendar via `watchtower caldav add`. The app password is
    /// NEVER passed as a flag/argv — it's written to the subprocess's stdin
    /// pipe (plus a trailing newline), then the pipe is closed. Returns true
    /// on success so the caller can dismiss the connect sheet.
    @discardableResult
    func addCalDAV(url: String, username: String, password: String, label: String) async -> Bool {
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

        var args = ["caldav", "add", "--url", url, "--username", username]
        if !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }

        let result = await Self.runCLI(path: cliPath, arguments: args, stdin: password + "\n")
        isRunning = false

        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the new calendar's first sync runs now.
            Task { await DaemonManager.restart() }
            return true
        } else {
            error = result.stderr.isEmpty
                ? "Connect failed (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
            return false
        }
    }

    // MARK: - Add ICS feed

    /// Adds a secret ICS feed via `watchtower caldav add-ics`. The feed URL is
    /// a CREDENTIAL (Google's "Secret address in iCal format" grants read
    /// access to the whole calendar) — it goes to the subprocess's stdin,
    /// never argv, and is never stored in the DB row.
    @discardableResult
    func addICS(feedURL: String, label: String) async -> Bool {
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

        var args = ["caldav", "add-ics"]
        if !label.isEmpty {
            args.append(contentsOf: ["--label", label])
        }

        let result = await Self.runCLI(path: cliPath, arguments: args, stdin: feedURL + "\n")
        isRunning = false

        if result.exitCode == 0 {
            error = nil
            refresh()
            // Re-wire the daemon so the new feed's first sync runs now.
            Task { await DaemonManager.restart() }
            return true
        } else {
            error = result.stderr.isEmpty
                ? "Connect failed (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
            return false
        }
    }

    // MARK: - Remove

    /// Builds the CLI args to disconnect `account` — `caldav remove <id>` for
    /// both providers (the CLI keys off the DB row, not a subcommand split).
    /// Pure and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for account: CalendarAccount) -> [String] {
        ["caldav", "remove", String(account.id)]
    }

    func remove(_ account: CalendarAccount) async {
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
    /// which is how the CalDAV password / secret ICS URL reaches the
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
