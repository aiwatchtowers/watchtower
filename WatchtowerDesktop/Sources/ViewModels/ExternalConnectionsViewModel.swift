import Foundation
import GRDB
import WatchtowerCore

/// Drives the "Quick Connections" list of owner-managed external MCP servers
/// shown in Settings → Connections. Each row is a DB-backed
/// `external_connections` record read directly via GRDB; mutations shell out
/// to the `watchtower connections` CLI (the DB never gets a direct write from
/// Desktop) so the same validation/config-writing path serves both the CLI
/// and the app. Owned by AppState so the list survives navigating away from
/// Settings — deliberate structural copy of `SlackAccountsViewModel` (house
/// pattern).
@MainActor
@Observable
final class ExternalConnectionsViewModel {
    private(set) var connections: [ExternalConnection] = []
    var isBusy = false
    var error: String?

    private let dbPool: DatabasePool
    private var authProcess: Process?

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    // MARK: - Refresh

    /// Cross-process writes (the CLI subprocess) don't fire GRDB's
    /// ValueObservation, so callers reload on appear / after a CLI call
    /// completes rather than observing live.
    func refresh() {
        Task { await refreshAsync() }
    }

    /// The awaitable body of `refresh()`, split out so tests can call it
    /// directly and observe `connections` deterministically instead of racing
    /// a detached `Task`.
    func refreshAsync() async {
        do {
            let rows = try await dbPool.read { db in try ExternalConnectionQueries.fetchAll(db) }
            self.connections = rows
        } catch {
            self.error = "Failed to load connections: \(error.localizedDescription)"
        }
    }

    // MARK: - Add

    /// Builds the `connections add` args — `--name`/`--kind` are always
    /// present; `--command`/`--arg` (repeated) for stdio, `--url` for http,
    /// and `--secret-stdin` whenever a secret is supplied (the secret value
    /// itself never appears here — it travels over the child process's
    /// stdin, see `addConnection` below). Pure and side-effect-free so the
    /// flag assembly is directly testable without shelling out to a real
    /// process.
    static func addArgs(
        name: String,
        kind: String,
        command: String,
        args: [String],
        url: String,
        hasSecret: Bool
    ) -> [String] {
        var result = ["connections", "add", "--name", name, "--kind", kind]
        if kind == "stdio" {
            if !command.isEmpty {
                result.append(contentsOf: ["--command", command])
            }
            for arg in args {
                result.append(contentsOf: ["--arg", arg])
            }
        } else {
            if !url.isEmpty {
                result.append(contentsOf: ["--url", url])
            }
        }
        if hasSecret {
            result.append("--secret-stdin")
        }
        return result
    }

    /// Adds a new connection via `watchtower connections add`. `secretJSON`
    /// — when provided — is the `{"env":{...},"headers":{...}}` payload
    /// written to the subprocess's stdin (plus a trailing newline) and is
    /// NEVER passed as a command-line argument; `nil`/empty means no secret
    /// and nothing is written to stdin.
    ///
    /// When `useOAuth` is set (http, OAuth sign-in chosen over manual
    /// headers), a successful add is followed by looking the new row up by
    /// its (unique) name and running `signIn` on it. The row is always
    /// created first — if the sign-in step then fails, the row stays
    /// (disabled) with `error` set; it is never rolled back.
    func addConnection(
        name: String,
        kind: String,
        command: String,
        args: [String],
        url: String,
        secretJSON: String?,
        useOAuth: Bool = false
    ) async {
        let hasSecret = secretJSON?.isEmpty == false
        var stdin: String?
        if hasSecret, let secretJSON {
            stdin = secretJSON + "\n"
        }
        await runManagementCommand(
            args: Self.addArgs(name: name, kind: kind, command: command, args: args, url: url, hasSecret: hasSecret),
            stdin: stdin,
            failurePrefix: "Add failed"
        )
        guard useOAuth, error == nil else { return }

        // `applyResult`'s `refresh()` is fire-and-forget — await our own pass
        // so the new row is guaranteed visible before we search for it by name.
        await refreshAsync()
        guard let row = connections.first(where: { $0.name == name }) else {
            error = "Added but could not find the new connection to sign in."
            return
        }
        await signIn(row)
    }

    // MARK: - OAuth sign-in

    /// Builds the `connections oauth <id>` args — always `--app-return` (the
    /// OAuth success page redirects to watchtower-auth:// so macOS brings the
    /// app back to the foreground). Pure and side-effect-free so the flag
    /// assembly is directly testable without shelling out to a real process.
    static func oauthArgs(id: Int64) -> [String] {
        ["connections", "oauth", String(id), "--app-return"]
    }

    /// Signs `connection` in via `watchtower connections oauth <id>
    /// --app-return` — the loopback-browser OAuth consent flow implemented by
    /// the CLI. The detached Process is held in `authProcess` so
    /// `cancelSignIn()` can terminate it mid-flow. Structural copy of
    /// `SlackAccountsViewModel.runAuthFlow`/`addAccount`.
    func signIn(_ connection: ExternalConnection) async {
        await runAuthFlow(args: Self.oauthArgs(id: Int64(connection.id)), failurePrefix: "Sign in failed")
    }

    /// Terminates an in-flight sign-in process, if any. Mirrors
    /// `SlackAccountsViewModel.cancelConnect` — the terminated process exits
    /// with SIGTERM/SIGKILL, which `applyResult` treats as a user cancel, not
    /// an error.
    func cancelSignIn() {
        if let process = authProcess, process.isRunning {
            process.terminate()
        }
        authProcess = nil
        isBusy = false
    }

    // MARK: - Enable / Disable

    /// Builds the CLI args to enable or disable `c` — `connections enable
    /// <id>` or `connections disable <id>`. Pure and side-effect-free.
    static func setEnabledArgs(for c: ExternalConnection, enabled: Bool) -> [String] {
        ["connections", enabled ? "enable" : "disable", String(c.id)]
    }

    /// Enables or disables `c` via `watchtower connections enable|disable
    /// <id>`.
    func setEnabled(_ c: ExternalConnection, enabled: Bool) async {
        await runManagementCommand(
            args: Self.setEnabledArgs(for: c, enabled: enabled),
            failurePrefix: enabled ? "Enable failed" : "Disable failed"
        )
    }

    // MARK: - Remove

    /// Builds the CLI args to remove `c` — `connections remove <id>`. Pure
    /// and side-effect-free so the dispatch is directly testable without
    /// shelling out to a real process.
    static func removeArgs(for c: ExternalConnection) -> [String] {
        ["connections", "remove", String(c.id)]
    }

    /// Removes `c` via `watchtower connections remove <id>`.
    func remove(_ c: ExternalConnection) async {
        await runManagementCommand(args: Self.removeArgs(for: c), failurePrefix: "Remove failed")
    }

    // MARK: - Flow helpers

    /// Browser-consent flow (`oauth`) — holds the detached Process in
    /// `authProcess` so `cancelSignIn()` can terminate it while this awaits.
    /// Structural copy of `SlackAccountsViewModel.runAuthFlow`.
    private func runAuthFlow(args: [String], failurePrefix: String) async {
        guard !isBusy else {
            error = "Another operation is already in progress."
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isBusy = true
        error = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        authProcess = process

        let result = await Self.runProcess(process)
        authProcess = nil
        isBusy = false
        applyResult(result, failurePrefix: failurePrefix)
    }

    private func runManagementCommand(args: [String], stdin: String? = nil, failurePrefix: String) async {
        guard !isBusy else {
            error = "Another operation is already in progress."
            return
        }
        guard let cliPath = Constants.findCLIPath() else {
            error = "Watchtower CLI not found"
            return
        }

        isBusy = true
        error = nil

        let result = await Self.runCLI(path: cliPath, arguments: args, stdin: stdin)
        isBusy = false
        applyResult(result, failurePrefix: failurePrefix)
    }

    private func applyResult(
        _ result: (exitCode: Int32, stdout: String, stderr: String),
        failurePrefix: String
    ) {
        if result.exitCode == 0 {
            error = nil
            // No DaemonManager.restart() here — Quick Connections feed
            // nothing in the daemon; `cmd/generator.go` reads the
            // external_connections table fresh on every `ai query`, so a
            // restart would be a redundant daemon bounce copied from
            // SlackAccountsViewModel (where the daemon does own live sync).
            refresh()
        } else if result.exitCode == 15 || result.exitCode == 9 {
            // SIGTERM/SIGKILL — user cancelled via cancelSignIn(), not an error.
            error = nil
        } else {
            error = result.stderr.isEmpty
                ? "\(failurePrefix) (exit \(result.exitCode))"
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

    /// Runs a pre-configured Process, reading pipe data before waitUntilExit
    /// to avoid deadlock. If `stdin` is provided, `process.standardInput`
    /// must already be a `Pipe` (see `runCLI` above) — the string is written
    /// to its `fileHandleForWriting` and the pipe is closed before draining
    /// output, which is how the connection secret reaches the subprocess
    /// without ever touching argv.
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
