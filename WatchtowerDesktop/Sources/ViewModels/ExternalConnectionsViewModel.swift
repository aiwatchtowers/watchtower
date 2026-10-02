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

    /// Per-connection tool lists (QC-02), loaded when the owner opens a
    /// connection's Tools; keyed by connection id.
    private(set) var toolLists: [Int: ExternalConnectionTools] = [:]
    /// Connections with a `connections tools` command running.
    private(set) var toolsInFlight: Set<Int> = []
    /// The last tools command's failure, per connection (cleared on success).
    private(set) var toolsErrors: [Int: String] = [:]

    private let dbPool: DatabasePool
    private let makeRunner: () -> (any CLIRunnerProtocol)?
    private var authProcess: Process?

    init(dbPool: DatabasePool,
         makeRunner: @escaping () -> (any CLIRunnerProtocol)? = { ProcessCLIRunner.makeDefault() }) {
        self.dbPool = dbPool
        self.makeRunner = makeRunner
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
        await reloadShownTools(connection) // a sign-in re-lists the tools
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
        await reloadShownTools(c) // enabling re-lists the tools
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
        if error == nil {
            toolLists[c.id] = nil
            toolsErrors[c.id] = nil
        }
    }

    // MARK: - Tools (QC-02)

    /// Loads `c`'s tool list (`connections tools <id> --json`, read-only).
    func loadTools(_ c: ExternalConnection) async {
        await runToolsCommand(c) { _ in ExternalConnectionTools.listArgs(id: Int64(c.id)) }
    }

    /// Re-lists `c`'s tools from its server (`--refresh`).
    func refreshTools(_ c: ExternalConnection) async {
        await runToolsCommand(c) { _ in ExternalConnectionTools.listArgs(id: Int64(c.id), refresh: true) }
    }

    /// Turns one tool on or off. The next allow list is built from a list
    /// read just before the write, never from the snapshot on screen, so a
    /// change made meanwhile (the CLI, a re-listing) is not overwritten.
    /// A tool the fresh list no longer has, or now marks a write (a
    /// re-listing changed it), is an error: the fresh list is shown and
    /// nothing is written.
    func setTool(_ name: String, allowed: Bool, on c: ExternalConnection) async {
        await runToolsCommand(c) { runner in
            let fresh = try await Self.decodeTools(runner.run(args: ExternalConnectionTools.listArgs(id: Int64(c.id))))
            guard let tool = fresh.tools.first(where: { $0.name == name }), tool.canToggle else {
                self.toolLists[c.id] = fresh
                throw ToolsCommandError.toolChanged(name)
            }
            return fresh.allowArgs(setting: name, allowed: allowed)
        }
    }

    /// Drops the explicit list: back to the read-only default (`--default`).
    func useDefaultTools(_ c: ExternalConnection) async {
        await runToolsCommand(c) { _ in ExternalConnectionTools.defaultArgs(id: Int64(c.id)) }
    }

    /// Re-reads the tools of a connection whose list is on screen, after a
    /// command that may have re-listed them.
    private func reloadShownTools(_ c: ExternalConnection) async {
        guard toolLists[c.id] != nil else { return }
        await loadTools(c)
    }

    /// Runs one `connections tools` command for `c` (the arguments may need
    /// a read first) and stores the list it prints. Every tools command can
    /// change the row's status (no allowed tool → `error`), so the
    /// connections reload after it, success or not. A second command for the
    /// same connection while one runs is dropped: the view disables the
    /// tools controls and the row's Enabled, Sign in and Remove meanwhile.
    /// When the output cannot be read, the list on screen is dropped too — a
    /// write may have landed, so the old toggles would no longer be true.
    private func runToolsCommand(
        _ c: ExternalConnection,
        args: (any CLIRunnerProtocol) async throws -> [String]
    ) async {
        guard !toolsInFlight.contains(c.id) else { return }
        guard let runner = makeRunner() else {
            toolsErrors[c.id] = "Watchtower CLI not found"
            return
        }
        toolsInFlight.insert(c.id)
        defer { toolsInFlight.remove(c.id) }
        do {
            let data = try await runner.run(args: args(runner))
            toolLists[c.id] = try Self.decodeTools(data)
            toolsErrors[c.id] = nil
        } catch {
            if error is DecodingError { toolLists[c.id] = nil }
            toolsErrors[c.id] = Self.toolsErrorText(error)
        }
        await refreshAsync()
    }

    private enum ToolsCommandError: LocalizedError {
        case toolChanged(String)

        var errorDescription: String? {
            switch self {
            case let .toolChanged(name):
                "\(name) changed on the server (gone, or now a write). The list is updated; nothing was changed."
            }
        }
    }

    nonisolated private static func decodeTools(_ data: Data) throws -> ExternalConnectionTools {
        try JSONDecoder().decode(ExternalConnectionTools.self, from: data)
    }

    /// The CLI's own message when it refused — the last stderr line (the
    /// error `Execute` prints; earlier lines are timestamped log output) —
    /// else the error.
    nonisolated private static func toolsErrorText(_ error: Error) -> String {
        if case let CLIRunnerError.nonZeroExit(code, stderr) = error {
            let last = stderr.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            return last.map { String($0.prefix(300)) } ?? "Tools command failed (exit \(code))"
        }
        if error is DecodingError {
            return "Could not read the tool list: \(error.localizedDescription)"
        }
        return error.localizedDescription
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

    /// Runs a pre-configured Process, draining stdout and stderr concurrently
    /// (`ProcessPipes`, SB3). If `stdin` is provided, `process.standardInput`
    /// must already be a `Pipe` (see `runCLI` above) — the string is written
    /// to its `fileHandleForWriting` and the pipe is closed before draining
    /// output, which is how the connection secret reaches the subprocess
    /// without ever touching argv.
    nonisolated private static func runProcess(
        _ process: Process,
        stdin: String? = nil
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        await ProcessPipes.run(process, stdin: stdin).trimmed
    }
}
