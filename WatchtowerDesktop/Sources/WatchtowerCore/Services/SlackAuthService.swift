import Foundation
import Yams

@MainActor
@Observable
package final class SlackAuthService {
    package var isConnected: Bool = false
    package var error: String?

    package init() {
        checkStatus()
    }

    // MARK: - Disconnect

    /// Runs `auth logout`: removes the Slack token (config + token file) and
    /// marks account #1 removed/disabled so syncing stops. Non-destructive —
    /// already-synced Slack data and the AI products built on it are KEPT
    /// (mirrors the `slack remove` / `removeSlackAccount` semantics).
    package func disconnect() async {
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
    package func checkStatus() {
        isConnected = Self.tokenPresent()
    }

    /// Whether config.yaml holds a non-empty slack_token for the active workspace.
    package nonisolated static func tokenPresent() -> Bool {
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

        let (exitCode, stdout, stderr) = await ProcessPipes.run(process).trimmed
        // A launch failure arrives here as exit -1 with the launch error as stderr.
        // The third ad-hoc Process wrapper in the app (after ProcessCLIRunner and
        // CatchUpViewModel's), so it logs the child's stderr itself: `disconnect`
        // turns it into one line of UI text, and a failed sign-out otherwise left
        // nothing behind to debug. Logged here rather than at the caller because
        // this helper is private and knows the arguments.
        if exitCode != 0 {
            CLILog.failure(args: arguments, exitCode: exitCode, stderr: stderr)
        } else {
            CLILog.warning(args: arguments, stderr: stderr)
        }
        return (exitCode, stdout, stderr)
    }
}
