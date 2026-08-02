import Foundation
import Yams

@MainActor
@Observable
final class JiraAuthService {
    var isConnected: Bool = false
    var isAuthenticating: Bool = false
    var error: String?
    var siteURL: String?
    var userDisplayName: String?

    private var authProcess: Process?

    init() {
        checkStatus()
    }

    // MARK: - Connect

    func connect() {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isAuthenticating = true
        error = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["jira", "login"]
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
                    self.readConfig()
                    // Re-wire the daemon so the first sync + AI cycle runs now.
                    Task { await DaemonManager.restart() }
                } else if result.exitCode == 15
                            || result.exitCode == 9 {
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
                arguments: ["jira", "logout"]
            )
            await MainActor.run {
                if result.exitCode == 0 {
                    self.isConnected = false
                    self.siteURL = nil
                    self.userDisplayName = nil
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
        // A token can be the legacy jira_token.json or a per-account
        // jira_token_<id>.json (multi-account, migration 00049).
        func hasToken(inDir dir: String) -> Bool {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                return false
            }
            return files.contains { $0.hasPrefix("jira_token") && $0.hasSuffix(".json") }
        }
        // Only the ACTIVE workspace's token counts — logout deletes the token
        // there, and a stale token in an old workspace must not read as connected.
        if let dir = Constants.activeWorkspaceDir() {
            isConnected = hasToken(inDir: dir)
            if isConnected { readConfig() }
            return
        }
        // No active workspace configured — fall back to scanning all workspaces.
        let basePath = Constants.databasePath
        guard let contents = try? FileManager.default.contentsOfDirectory(
            atPath: basePath
        ) else {
            isConnected = false
            return
        }
        isConnected = contents.contains { hasToken(inDir: "\(basePath)/\($0)") }
        if isConnected { readConfig() }
    }

    // MARK: - Config Reader

    private func readConfig() {
        // Site URL comes from jira_accounts when the pool is wired (the config
        // keys are frozen since multi-account); the yaml fallback inside
        // readSiteURL covers pre-migration installs.
        siteURL = JiraConfigHelper.readSiteURL()
        let configPath = Constants.configPath
        guard let data = FileManager.default.contents(atPath: configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any],
              let jira = yaml["jira"] as? [String: Any] else {
            return
        }
        userDisplayName = jira["user_display_name"] as? String
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

        let stdoutData = stdoutPipe.fileHandleForReading
            .readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading
            .readDataToEndOfFile()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutData, encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(
            data: stderrData, encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }
}
