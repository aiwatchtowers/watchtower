import Foundation
import Observation

/// Where onboarding's background people load is.
package enum PeopleRosterState: Equatable, Sendable {
    case idle
    /// `saved == 0` while users.list pages arrive (`fetched` is the running
    /// count, Slack gives no total up front); then `saved` of `fetched`.
    case loading(fetched: Int, saved: Int)
    case done(count: Int)
    case failed(String)
}

/// Onboarding's `watchtower sync --users-only --progress-json` run, started
/// once a Slack account is connected so About you's people pickers have the
/// roster. Held by `AppState`: the run keeps going while the owner moves on
/// to About you, which reads `state`. `stop()` (app quit) terminates the
/// child.
@MainActor
@Observable
package final class PeopleRosterLoad {
    /// Runs the load for one Slack account, feeding each stdout line to
    /// `onLine`; returns the exit code and stderr. Cancelling the calling
    /// task must end the child.
    package typealias Run = (
        _ accountID: Int,
        _ onLine: @escaping @MainActor (String) -> Void
    ) async -> (exitCode: Int32, stderr: String)

    package private(set) var state: PeopleRosterState = .idle

    @ObservationIgnored private let run: Run
    @ObservationIgnored private var task: Task<Void, Never>?

    package init(run: @escaping Run = PeopleRosterLoad.cliRun) {
        self.run = run
    }

    /// Starts the load for `accountID` unless one is running or has already
    /// finished; after a failure it starts again (Retry). Returns whether it
    /// started.
    @discardableResult
    package func start(accountID: Int) -> Bool {
        switch state {
        case .loading, .done: return false
        case .idle, .failed: break
        }
        state = .loading(fetched: 0, saved: 0)
        task = Task { [run] in
            var lastTotal = 0
            var lastError: String?
            let decoder = JSONDecoder()
            let result = await run(accountID) { [weak self] line in
                guard let progress = try? decoder.decode(SyncProgressData.self, from: Data(line.utf8)) else { return }
                if let error = progress.error, !error.isEmpty {
                    lastError = error
                    return
                }
                lastTotal = progress.userProfilesTotal
                if case .loading = self?.state {
                    self?.state = .loading(fetched: progress.userProfilesTotal, saved: progress.userProfilesDone)
                }
            }
            guard !Task.isCancelled else { return }
            if result.exitCode == 0 {
                state = .done(count: lastTotal)
            } else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                state = .failed(lastError ?? (stderr.isEmpty ? "exit code \(result.exitCode)" : String(stderr.prefix(300))))
            }
        }
        return true
    }

    /// Waits for the current run, if any.
    package func waitForCompletion() async {
        await task?.value
    }

    /// Ends a running load (app quit); a later `start` begins again.
    package func stop() {
        task?.cancel()
        task = nil
        if case .loading = state { state = .idle }
    }

    /// The real child process. Cancellation sends it SIGTERM.
    package nonisolated static func cliRun(
        accountID: Int,
        onLine: @escaping @MainActor (String) -> Void
    ) async -> (exitCode: Int32, stderr: String) {
        guard let path = Constants.findCLIPath() else { return (-1, "Watchtower CLI not found") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["sync", "--users-only", "--progress-json", "--account", "\(accountID)"]
        process.environment = Constants.resolvedEnvironment()
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        return await withTaskCancellationHandler {
            let stderrRead = ProcessPipes.drain(stderrPipe)
            for await line in stdoutPipe.fileHandleForReading.ndjsonLines {
                await onLine(line)
            }
            let stderr = String(data: await stderrRead.value, encoding: .utf8) ?? ""
            await ProcessPipes.offPool { process.waitUntilExit() }
            return (process.terminationStatus, stderr)
        } onCancel: {
            process.terminate()
        }
    }
}
