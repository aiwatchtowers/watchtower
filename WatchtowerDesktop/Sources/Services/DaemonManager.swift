import Foundation
import WatchtowerCore

@MainActor
@Observable
final class DaemonManager {
    var isRunning = false
    var lastSyncTime: Date?
    var watchtowerPath: String?
    var errorMessage: String?

    private var pollTask: Task<Void, Never>?

    init() {
        // Defer path lookup to first use to avoid blocking init
    }

    func resolvePathIfNeeded() {
        guard watchtowerPath == nil else { return }
        watchtowerPath = Self.findWatchtowerSync()
    }

    func startPolling() {
        resolvePathIfNeeded()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkStatus()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func checkStatus() {
        isRunning = Self.isDaemonRunning()
    }

    // C4 fix: async to avoid blocking main thread
    func startDaemon() async {
        resolvePathIfNeeded()
        guard let path = watchtowerPath else {
            errorMessage = "watchtower binary not found in PATH"
            return
        }

        do {
            let status = try await Self.runProcess(path: path, arguments: ["sync", "--daemon", "--detach"])
            if status == 0 {
                isRunning = true
                errorMessage = nil
            } else {
                errorMessage = "Failed to start daemon (exit code \(status))"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // C4 fix: async to avoid blocking main thread
    func stopDaemon() async {
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

    /// Public entry point for external callers (e.g. DataSettings reset).
    nonisolated static func checkDaemonRunning() -> Bool {
        isDaemonRunning()
    }

    /// Restart the detached daemon. Source syncers (Calendar, Gmail, Jira) are
    /// wired only at daemon startup, and the daemon runs an immediate sync +
    /// pipeline cycle on start — so a restart right after connecting a source
    /// makes its data and AI products appear right away instead of waiting for
    /// the next poll.
    nonisolated static func restart() async {
        guard let path = Constants.findCLIPath() else { return }
        _ = try? await runProcess(path: path, arguments: ["sync", "stop"])
        _ = try? await runProcess(path: path, arguments: ["sync", "--daemon", "--detach"])
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
    nonisolated static func stopDaemonBounded(
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
        let dataPath = Constants.databasePath
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(atPath: dataPath) else { return false }

        for dir in contents {
            guard !dir.hasPrefix(".") else { continue }
            let pidPath = "\(dataPath)/\(dir)/daemon.pid"
            guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else { continue }

            // PID file may contain "PID TIMESTAMP" format
            let pidComponent = pidStr.components(separatedBy: " ").first ?? pidStr
            guard let pid = pid_t(pidComponent) else { continue }

            if kill(pid, 0) == 0 {
                return true
            }
        }

        return false
    }

    nonisolated private static func findWatchtowerSync() -> String? {
        Constants.findCLIPath()
    }
}
