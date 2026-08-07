import Foundation

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

    /// Run a process off the main thread
    nonisolated private static func runProcess(path: String, arguments: [String]) async throws -> Int32 {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.currentDirectoryURL = Constants.processWorkingDirectory()
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
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

    /// Stop the daemon for app quit: `sync stop` (the daemon gets up to 10 s
    /// of SIGTERM grace from the CLI) with an outer watchdog so a hung CLI
    /// can never stall termination.
    nonisolated static func stopForQuit(timeout: Duration = .seconds(12)) async {
        guard let path = Constants.findCLIPath() else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await runProcess(path: path, arguments: ["sync", "stop"]) }
            group.addTask { try? await Task.sleep(for: timeout) }
            _ = await group.next()
            group.cancelAll()
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
