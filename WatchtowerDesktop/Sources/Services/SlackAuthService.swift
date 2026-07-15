import Foundation
import Yams

@MainActor
@Observable
final class SlackAuthService {
    var isConnected: Bool = false
    var error: String?

    init() {
        checkStatus()
    }

    // MARK: - Disconnect

    /// Runs `auth logout`: removes the Slack token from config and purges all
    /// Slack data (and the AI products built on it) from the database.
    func disconnect() async {
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        let result = await Self.runCLI(path: cliPath, arguments: ["auth", "logout"])
        if result.exitCode == 0 {
            isConnected = false
            error = nil
        } else {
            error = result.stderr.isEmpty
                ? "Disconnect failed (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
        }
    }

    // MARK: - Status

    /// Connected = a non-empty slack_token for the active workspace in config.yaml.
    func checkStatus() {
        isConnected = Self.tokenPresent()
    }

    /// Whether config.yaml holds a non-empty slack_token for the active workspace.
    nonisolated static func tokenPresent() -> Bool {
        guard let data = FileManager.default.contents(atPath: Constants.configPath),
              let str = String(data: data, encoding: .utf8),
              let yaml = try? Yams.load(yaml: str) as? [String: Any],
              let workspace = yaml["active_workspace"] as? String,
              let workspaces = yaml["workspaces"] as? [String: Any],
              let ws = workspaces[workspace] as? [String: Any],
              let token = ws["slack_token"] as? String else {
            return false
        }
        return !token.isEmpty
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
