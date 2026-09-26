import Foundation

// MARK: - DaemonRestartError

/// Why `DaemonManager.restart()` failed to leave a live daemon behind.
package enum DaemonRestartError: LocalizedError, Equatable {
    /// `sync stop` returned non-zero and the daemon still had not exited by
    /// `restartStopGrace` — `--detach` was never attempted, since starting
    /// one next to a process that might still be live would risk two
    /// daemons. `pid` is nil only if the pid file vanished between the
    /// timeout firing and the diagnostic re-read (the process is still gone
    /// either way).
    case stopTimedOut(pid: pid_t?)
    /// `sync --daemon --detach` itself exited non-zero.
    case startFailed(status: Int32, stderr: String)
    /// No `watchtower` binary was resolvable at all — `restart()` did
    /// nothing, which must not read as a quiet success.
    case cliNotFound

    package var errorDescription: String? {
        switch self {
        case .stopTimedOut(let pid):
            let who = pid.map { "pid \($0)" } ?? "the old daemon"
            let graceSeconds = Int(DaemonManager.restartStopGrace.components.seconds)
            return "Daemon restart: \(who) did not stop within \(graceSeconds)s; refusing to start a second daemon"
        case let .startFailed(status, stderr):
            return DaemonManager.startFailureMessage(status: status, stderr: stderr)
        case .cliNotFound:
            return "watchtower binary not found in PATH"
        }
    }
}

// MARK: - PidWaitOutcome

/// Result of `DaemonManager.waitForPidDeath`.
enum PidWaitOutcome: Equatable {
    case died
    case timedOut
}

@MainActor
@Observable
package final class DaemonManager {
    package var isRunning = false
    /// The daemon's live sync heartbeat, refreshed by `checkStatus()`. nil when
    /// no heartbeat file exists yet (no sync has run since the daemon shipped
    /// this file) — read it through `SyncProgress.isSyncing`, never through
    /// `active` alone.
    package var syncProgress: SyncProgress?
    package var lastSyncTime: Date?
    package var watchtowerPath: String?
    package var errorMessage: String?

    private var pollTask: Task<Void, Never>?

    package init() {
        // Defer path lookup to first use to avoid blocking init
    }

    package func resolvePathIfNeeded() {
        guard watchtowerPath == nil else { return }
        watchtowerPath = Self.findWatchtowerSync()
    }

    package func startPolling() {
        resolvePathIfNeeded()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkStatus()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    package func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    package func checkStatus() {
        isRunning = Self.isDaemonRunning()
        syncProgress = Self.readSyncProgress()
    }

    /// Reads the active workspace's sync heartbeat. Scoped to the active
    /// workspace (not a scan of every workspace dir, unlike the PID check):
    /// another workspace's stale heartbeat would misreport this one's state.
    nonisolated package static func readSyncProgress() -> SyncProgress? {
        guard let dir = Constants.activeWorkspaceDir(),
              let data = FileManager.default.contents(atPath: "\(dir)/sync_progress.json")
        else { return nil }
        return try? JSONDecoder().decode(SyncProgress.self, from: data)
    }

    /// Asks the running daemon to sync now (SIGUSR1 via the CLI) instead of
    /// waiting for its next poll. Does nothing useful without a daemon — the
    /// CLI exits non-zero, which lands in `errorMessage` — because the daemon
    /// holds an exclusive lock on syncing.
    package func syncNow() async {
        resolvePathIfNeeded()
        guard let path = watchtowerPath else {
            errorMessage = "watchtower binary not found in PATH"
            return
        }
        do {
            let status = try await Self.runProcess(path: path, arguments: ["sync", "--now"])
            errorMessage = status == 0 ? nil : "Failed to request a sync (exit code \(status))"
            if status == 0 {
                checkStatus()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // C4 fix: async to avoid blocking main thread
    package func startDaemon() async {
        resolvePathIfNeeded()
        guard let path = watchtowerPath else {
            errorMessage = "watchtower binary not found in PATH"
            return
        }

        do {
            let result = try await Self.runProcessCapturingStderr(path: path, arguments: ["sync", "--daemon", "--detach"])
            if result.status == 0 {
                isRunning = true
                errorMessage = nil
            } else {
                errorMessage = Self.startFailureMessage(status: result.status, stderr: result.stderr)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The Settings error line for a failed start. The CLI's stderr is the
    /// only diagnostic when `sync --daemon --detach` rejects the config: that
    /// happens before the daemon opens daemon.log, so the log stays empty.
    nonisolated static func startFailureMessage(status: Int32, stderr: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "Failed to start daemon (exit code \(status))"
        return detail.isEmpty ? base : "\(base): \(detail)"
    }

    // C4 fix: async to avoid blocking main thread
    package func stopDaemon() async {
        guard let path = watchtowerPath else { return }

        do {
            let status = try await Self.runProcess(path: path, arguments: ["sync", "stop"])
            if status == 0 {
                isRunning = false
                errorMessage = nil
            } else {
                errorMessage = "Failed to stop daemon (exit code \(status))"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The one place CLI subprocesses are configured (working directory, muted
    /// output), shared by the unbounded `runProcess` and the bounded stop.
    nonisolated private static func makeProcess(path: String, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Run a process off the main thread
    nonisolated private static func runProcess(path: String, arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = makeProcess(path: path, arguments: arguments)
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    /// `runProcess` with the child's stderr kept instead of muted, for the one
    /// call whose failure has no other trace (see `startFailureMessage`).
    /// The pipe is drained before `waitUntilExit` so a chatty child cannot
    /// block on a full pipe.
    nonisolated private static func runProcessCapturingStderr(
        path: String,
        arguments: [String]
    ) async throws -> (status: Int32, stderr: String) {
        try await Task.detached {
            let process = makeProcess(path: path, arguments: arguments)
            let pipe = Pipe()
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Latin-1 never fails, so a non-UTF-8 diagnostic degrades to mojibake
            // instead of vanishing.
            let stderr = String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
            return (process.terminationStatus, stderr)
        }.value
    }

    /// Public entry point for external callers (e.g. DataSettings reset).
    package nonisolated static func checkDaemonRunning() -> Bool {
        isDaemonRunning()
    }

    /// Restart the detached daemon. Source syncers (Calendar, Gmail, Jira) are
    /// wired only at daemon startup, and the daemon runs an immediate sync +
    /// pipeline cycle on start — so a restart right after connecting a source
    /// makes its data and AI products appear right away instead of waiting for
    /// the next poll.
    ///
    /// Never leaves the system without a daemon (H11, owner decision 10): a
    /// `sync stop` that returns non-zero (normal while an AI call is in
    /// flight — the CLI gives it only 10 s of SIGTERM grace) does not mean
    /// the daemon is dead, and starting `--detach` next to a still-live one
    /// would either get refused ("already running") after the old one dies
    /// moments later — leaving no daemon until the app relaunches — or, in
    /// the worse case, race a second one in. So a non-zero stop is followed
    /// by polling pid liveness up to `restartStopGrace`; `--detach` runs only
    /// once the pid is confirmed dead, and `.stopTimedOut` is thrown instead
    /// of attempted if it never dies.
    package nonisolated static func restart() async throws {
        guard let path = Constants.findCLIPath() else {
            throw DaemonRestartError.cliNotFound
        }

        var stopStatus: Int32 = 1
        do {
            stopStatus = try await runProcess(path: path, arguments: ["sync", "stop"])
        } catch {
            NSLog("DaemonManager: restart: `sync stop` failed to spawn: %@", error.localizedDescription)
        }

        if stopStatus != 0 {
            let outcome = await waitForPidDeath(
                isAlive: { activeWorkspaceDaemonPID() != nil },
                step: restartPollStep,
                deadline: restartStopGrace
            )
            if outcome == .timedOut {
                throw DaemonRestartError.stopTimedOut(pid: activeWorkspaceDaemonPID())
            }
        }

        let result = try await runProcessCapturingStderr(path: path, arguments: ["sync", "--daemon", "--detach"])
        if result.status != 0 {
            throw DaemonRestartError.startFailed(status: result.status, stderr: result.stderr)
        }
    }

    /// Fire-and-forget convenience for the many call sites that kick off a
    /// restart after a background account change (a new Slack/Google/Jira
    /// connection, an account removal) and cannot usefully react to its
    /// result beyond making sure a failure is never silent.
    package nonisolated static func restartLogging() async {
        do {
            try await restart()
        } catch {
            NSLog("DaemonManager: restart failed: %@", error.localizedDescription)
        }
    }

    /// Bound on how long `restart()` waits for a `sync stop` that returned
    /// non-zero to actually take the daemon down before it gives up and
    /// refuses to start a second one next to a possibly-still-live process.
    /// Generous on purpose: `sync stop`'s own SIGTERM grace is only 10 s, and
    /// an in-flight AI call routinely outlasts that — this is the ceiling on
    /// how long a restart may leave the system without a daemon at all, not
    /// a redundant timeout layered on top of the CLI's.
    package nonisolated static let restartStopGrace: Duration = .seconds(60)

    /// Poll interval while waiting out `restartStopGrace`.
    nonisolated private static let restartPollStep: Duration = .milliseconds(250)

    /// Polls `isAlive` every `step` until it reports death or `deadline`
    /// (wall time from the first call) elapses. Pure aside from the clock
    /// read and the sleep: `isAlive` is the only I/O seam, so both branches
    /// are pinned with a fake counter instead of a real process.
    nonisolated static func waitForPidDeath(
        isAlive: () -> Bool,
        step: Duration,
        deadline: Duration
    ) async -> PidWaitOutcome {
        let start = ContinuousClock.now
        while isAlive() {
            if ContinuousClock.now - start >= deadline {
                return .timedOut
            }
            try? await Task.sleep(for: step)
        }
        return .died
    }

    /// How long a terminated `sync stop` gets to actually die before the wait
    /// gives up and says so.
    nonisolated private static let sigtermGrace: Duration = .milliseconds(250)

    /// Stop the daemon with a bounded wait: `sync stop` (the daemon gets up to
    /// 10 s of SIGTERM grace from the CLI) under an outer watchdog. If the CLI
    /// hangs, the watchdog terminates the subprocess once the timeout expires,
    /// so no caller can block forever — the next launch adopts or replaces the
    /// daemon. Used by both callers that cannot afford an open-ended wait: the
    /// quit path (`terminateLater` must reply) and the launch path (the store
    /// sync runs before the database opens, behind the splash).
    package nonisolated static func stopDaemonBounded(
        timeout: Duration = .seconds(12),
        cliPath: String? = Constants.findCLIPath()
    ) async {
        guard let path = cliPath else { return }

        let process = makeProcess(path: path, arguments: ["sync", "stop"])
        do {
            try process.run()
        } catch {
            NSLog("DaemonManager: could not spawn `sync stop` at %@: %@", path, error.localizedDescription)
            return
        }

        // Race: process exit vs timeout. Timeout wins → terminate subprocess
        let startTime = ContinuousClock.now
        while process.isRunning && ContinuousClock.now - startTime < timeout {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        // Observe the outcome instead of sleeping blind: SIGTERM is a request,
        // and a child that ignores it is worth a line in the log.
        let terminateStart = ContinuousClock.now
        while process.isRunning && ContinuousClock.now - terminateStart < sigtermGrace {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if process.isRunning {
            NSLog("DaemonManager: `sync stop` (pid %d) survived SIGTERM; leaving it to the OS", pid)
        }
    }

    nonisolated private static func isDaemonRunning() -> Bool {
        runningDaemonPID() != nil
    }

    /// Reads a `daemon.pid` file (`"PID"` or `"PID TIMESTAMP"`) and confirms
    /// liveness via `kill(pid, 0)`. The one parsing routine shared by the
    /// broad, all-workspaces scan (`runningDaemonPID`) and the active-workspace-
    /// only lookup `restart()` actually needs (`activeWorkspaceDaemonPID`) —
    /// factored out so a test can pin it against a temp file directly, without
    /// touching `Constants.databasePath`.
    nonisolated static func livePID(atPath pidPath: String) -> pid_t? {
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        // PID file may contain "PID TIMESTAMP" format
        let pidComponent = pidStr.components(separatedBy: " ").first ?? pidStr
        guard let pid = pid_t(pidComponent), pid > 0 else { return nil }
        // pid 0 addresses the caller's own process group and pid <= 0 has its
        // own special meanings to `kill(2)` — none of them "a daemon we
        // started", so a corrupt/zeroed pid file must never read as live.

        return kill(pid, 0) == 0 ? pid : nil
    }

    /// Scans every workspace's `daemon.pid` for a live process (not scoped to
    /// the active workspace, unlike `readSyncProgress` — a daemon can be
    /// running against ANY workspace and must still count for the broad
    /// "is any daemon alive" question `isDaemonRunning()`/`checkDaemonRunning()`
    /// ask). Returns the pid of the first live one found. `restart()` itself
    /// does NOT use this — see `activeWorkspaceDaemonPID()` — a stale pid file
    /// in an unrelated workspace must never make `restart()` wait out the
    /// whole `restartStopGrace` for a daemon it was never trying to stop.
    nonisolated private static func runningDaemonPID() -> pid_t? {
        let dataPath = Constants.databasePath
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: dataPath) else { return nil }

        for dir in contents {
            guard !dir.hasPrefix(".") else { continue }
            if let pid = livePID(atPath: "\(dataPath)/\(dir)/daemon.pid") {
                return pid
            }
        }

        return nil
    }

    /// The active workspace's own `daemon.pid` — what `sync stop`/`sync
    /// --daemon --detach` actually operate on (`cmd/sync.go`'s
    /// `pidFilePath(cfg)`). This is what `restart()`'s wait loop must poll:
    /// the broad `runningDaemonPID()` scan sees every workspace directory
    /// (several, on a machine with worktree-derived workspaces), and a
    /// stale/reused pid in an unrelated one would otherwise make `restart()`
    /// spin out the full `restartStopGrace` and refuse to bring the actual
    /// daemon back. Falls back to the broad scan (logged) only when the
    /// active workspace itself cannot be resolved — still safer than
    /// skipping the liveness check outright.
    nonisolated private static func activeWorkspaceDaemonPID() -> pid_t? {
        guard let dir = Constants.activeWorkspaceDir() else {
            NSLog("DaemonManager: restart: active workspace is ambiguous; falling back to a scan of every workspace's daemon.pid")
            return runningDaemonPID()
        }
        return livePID(atPath: "\(dir)/daemon.pid")
    }

    nonisolated private static func findWatchtowerSync() -> String? {
        Constants.findCLIPath()
    }
}
