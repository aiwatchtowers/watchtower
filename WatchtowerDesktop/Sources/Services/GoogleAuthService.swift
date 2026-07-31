import Foundation
import GRDB

@MainActor
@Observable
final class GoogleAuthService {
    var isConnected: Bool = false
    var isAuthenticating: Bool = false
    var error: String?

    private var authProcess: Process?
    private var dbPool: DatabasePool?

    init() {}

    /// Wires DB access once AppState's pool is available. This service can be
    /// constructed before the pool exists — `GoogleConnectFlow.shared` (whose
    /// `calendar` property is this class) is a `static let` singleton built
    /// at first access, before `AppState.initialize()` has necessarily run —
    /// so `isConnected` stays `false` until this fires. Immediately re-checks
    /// status. Called from `AppState.initGoogleAccounts`.
    func configure(dbPool: DatabasePool) {
        self.dbPool = dbPool
        checkStatus()
    }

    // MARK: - Connect

    /// Runs the Calendar OAuth (re-)consent flow. With `accountID` (the
    /// reconnect-alert path — see `Navigation.swift`'s
    /// `reconnectAndRestartDaemon`), targets that SPECIFIC account via
    /// `watchtower google login --account <id>` (re-requests exactly its
    /// currently-enabled services — `calendar login`'s own alias semantics,
    /// just pinned to a known-broken account instead of the CLI's generic
    /// "account #1"). Without one, falls back to the generic `calendar
    /// login`, which resolves to whichever account the CLI treats as #1
    /// (`resolveAccountOneForLogin`) — reconnecting a healthy account #1
    /// while a DIFFERENT account is the one that's actually broken is
    /// exactly the bug `accountID` exists to prevent (N2).
    func connect(accountID: Int? = nil) {
        guard !isAuthenticating else { return }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isAuthenticating = true
        error = nil

        // Store the process so cancelConnect() can terminate it
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        // --app-return: the success page redirects to watchtower-auth:// so
        // macOS brings the app back to the foreground after the browser step.
        if let accountID {
            process.arguments = ["google", "login", "--account", String(accountID), "--app-return"]
        } else {
            process.arguments = ["calendar", "login", "--app-return"]
        }
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        Task.detached {
            let result = await Self.runProcess(process)
            await MainActor.run {
                self.authProcess = nil
                self.isAuthenticating = false
                if result.exitCode == 0 {
                    self.error = nil
                    // Re-read from the DB rather than assuming — the CLI
                    // writes the google_accounts row before exiting, so this
                    // reflects exactly what got granted.
                    Task { await self.checkStatusAsync() }
                    // Re-wire the daemon so the first sync + AI cycle runs now.
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
        isAuthenticating = false
    }

    // MARK: - Status

    /// Fire-and-forget status refresh — DB-derived (any `google_accounts` row
    /// with `calendar_enabled=1 AND status='ok'`), unlike the old per-
    /// account-#1 token-file stat, which only ever reflected a single
    /// account and couldn't distinguish Calendar from Gmail.
    func checkStatus() {
        Task { await checkStatusAsync() }
    }

    /// The awaitable body of `checkStatus()` — callers that need the fresh
    /// DB-derived value before continuing (e.g. `GoogleConnectFlow.
    /// finishConnect` deciding what was actually granted) must await this
    /// directly instead of racing the fire-and-forget `checkStatus()`.
    func checkStatusAsync() async {
        guard let dbPool else {
            isConnected = false
            return
        }
        do {
            isConnected = try await dbPool.read { db in try GoogleAccountQueries.hasConnectedCalendarAccount(db) }
        } catch {
            isConnected = false
        }
    }

    // MARK: - CLI Helper

    /// Runs a pre-configured Process, reading pipe data before waitUntilExit to avoid deadlock.
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
