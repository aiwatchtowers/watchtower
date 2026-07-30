import Foundation

@MainActor
@Observable
final class GmailAuthService {
    var isConnected: Bool = false
    var isAuthenticating: Bool = false
    var error: String?

    private var authProcess: Process?

    init() {
        checkStatus()
    }

    // MARK: - Connect

    func connect() {
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
        process.arguments = ["gmail", "login", "--app-return"]
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        Task.detached {
            let result = await Self.runProcess(process)
            await MainActor.run {
                self.authProcess = nil
                self.isAuthenticating = false
                if result.exitCode == 0 {
                    self.isConnected = true
                    self.error = nil
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

    // MARK: - Disconnect

    func disconnect() {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        Task.detached {
            let result = await Self.runCLI(
                path: cliPath,
                arguments: ["gmail", "logout"]
            )
            await MainActor.run {
                if result.exitCode == 0 {
                    self.isConnected = false
                    self.error = nil
                    // Restart so the daemon drops the disconnected syncer.
                    Task { await DaemonManager.restart() }
                } else {
                    self.error = result.stderr.isEmpty
                        ? "Disconnect failed (exit \(result.exitCode))"
                        : String(result.stderr.prefix(200))
                }
            }
        }
    }

    // MARK: - Status

    func checkStatus() {
        let fm = FileManager.default
        // Multi-account Google (Task 1-10): both Calendar and Gmail access for
        // account #1 share one token file, google_token_1.json (NOT
        // gmail_token.json — see calendar/auth.go's NewAccountTokenStore /
        // gmail/auth.go's matching comment). The legacy single-account
        // gmail_token.json is migrated into it in place by
        // ensureLegacyGoogleAccount (cmd/google_legacy.go), which the daemon
        // runs on every sync, so this stays accurate moments after a fresh
        // install's first sync completes. This service only reflects account
        // #1; a second+ account is a `GoogleAccountsViewModel` row.
        //
        // Only the ACTIVE workspace's token counts — logout deletes the token
        // there, and a stale token in an old workspace must not read as connected.
        if let dir = Constants.activeWorkspaceDir() {
            isConnected = fm.fileExists(atPath: "\(dir)/google_token_1.json")
            return
        }
        // No active workspace configured — fall back to scanning all workspaces.
        let basePath = Constants.databasePath
        guard let contents = try? fm.contentsOfDirectory(atPath: basePath) else {
            isConnected = false
            return
        }
        isConnected = contents.contains { fm.fileExists(atPath: "\(basePath)/\($0)/google_token_1.json") }
    }

    // MARK: - CLI Helper

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
