import Foundation
import GRDB

@MainActor
@Observable
package final class SlackAuthService {
    package var isConnected: Bool = false
    /// The workspace a Workspace-level Disconnect would remove, nil when that
    /// action must not be offered — see `logoutTarget(in:)`.
    package private(set) var disconnectTarget: SlackAccount?
    /// The error to show: a failed disconnect first, else a failed status
    /// read. Kept as two sources so a successful read clears only its own
    /// error, never a disconnect failure.
    package var error: String? { disconnectError ?? statusError }
    private var disconnectError: String?
    private var statusError: String?

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
    /// Returns whether the logout itself succeeded — the CLI result, never the
    /// combined `error`, which also carries status-read failures.
    @discardableResult
    package func disconnect() async -> Bool {
        guard let cliPath = Constants.findCLIPath() else {
            disconnectError = "Watchtower CLI not found"
            return false
        }
        let result = await Self.runCLI(path: cliPath, arguments: ["auth", "logout"])
        return await applyDisconnectResult(exitCode: result.exitCode, stderr: result.stderr)
    }

    /// Records a finished `auth logout`; split out of `disconnect()` so the
    /// bookkeeping is testable without a CLI.
    package func applyDisconnectResult(exitCode: Int32, stderr: String) async -> Bool {
        guard exitCode == 0 else {
            disconnectError = stderr.isEmpty
                ? "Disconnect failed (exit \(exitCode))"
                : String(stderr.prefix(200))
            return false
        }
        disconnectError = nil
        // `auth logout` removes account #1 only; any other connected
        // account keeps Slack connected.
        await refreshStatus()
        return true
    }

    /// Drops a stale disconnect failure — called after a successful
    /// reconnect/login, which supersedes it.
    package func clearDisconnectError() {
        disconnectError = nil
    }

    // MARK: - Status

    /// Connected = at least one enabled, non-removed `slack_accounts` row
    /// (`SlackAccountQueries.hasConnectedAccount`) — the same test onboarding
    /// uses. Not the config.yaml `slack_token`, which the multi-account CLI
    /// no longer writes. Without a database nothing is connected.
    package func refreshStatus() async {
        guard let dbPool else {
            isConnected = false
            disconnectTarget = nil
            return
        }
        do {
            let (connected, rows) = try await dbPool.read { db in
                (try SlackAccountQueries.hasConnectedAccount(db), try SlackAccountQueries.fetchAll(db))
            }
            let target = Self.logoutTarget(in: rows)
            // A disconnect failure is about the account it targeted; once
            // that target is gone or replaced, the error has nothing left to
            // describe (and the button that retries it may be hidden).
            if target?.id != disconnectTarget?.id {
                disconnectError = nil
            }
            isConnected = connected
            disconnectTarget = target
            statusError = nil
        } catch {
            isConnected = false
            disconnectTarget = nil
            statusError = "Couldn't read Slack accounts: \(error.localizedDescription)"
        }
    }

    /// The account `auth logout` removes — `cmd/auth.go` takes the lowest-id
    /// row of the whole table (`ListSlackAccounts()[0]`, removed rows
    /// included) — returned only while that row is itself connected. Once #1
    /// is removed or disabled, a Disconnect would re-remove it and leave every
    /// other workspace connected, so it is not offered at all; those accounts
    /// are managed per row in the Workspaces list.
    package nonisolated static func logoutTarget(in accounts: [SlackAccount]) -> SlackAccount? {
        guard let first = accounts.min(by: { $0.id < $1.id }),
              first.enabled, first.status != "removed" else { return nil }
        return first
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
