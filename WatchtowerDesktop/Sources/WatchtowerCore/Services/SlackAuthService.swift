import Foundation
import GRDB

@MainActor
@Observable
package final class SlackAuthService {
    package var isConnected: Bool = false
    package var error: String?

    private var dbPool: DatabasePool?

    package init() {}

    /// Wires DB access (the pool may not exist yet when the owning view is
    /// built); call `refreshStatus()` afterwards.
    package func configure(dbPool: DatabasePool?) {
        self.dbPool = dbPool
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
            error = nil
            // `auth logout` removes account #1 only; any other connected
            // account keeps Slack connected.
            await refreshStatus()
        } else {
            error = result.stderr.isEmpty
                ? "Disconnect failed (exit \(result.exitCode))"
                : String(result.stderr.prefix(200))
        }
    }

    // MARK: - Status

    /// Connected = at least one enabled, non-removed `slack_accounts` row
    /// (`SlackAccountQueries.hasConnectedAccount`) — the same test onboarding
    /// uses. Not the config.yaml `slack_token`, which the multi-account CLI
    /// no longer writes. Without a database nothing is connected.
    package func refreshStatus() async {
        guard let dbPool else {
            isConnected = false
            return
        }
        do {
            isConnected = try await dbPool.read { db in try SlackAccountQueries.hasConnectedAccount(db) }
        } catch {
            isConnected = false
            self.error = "Couldn't read Slack accounts: \(error.localizedDescription)"
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
