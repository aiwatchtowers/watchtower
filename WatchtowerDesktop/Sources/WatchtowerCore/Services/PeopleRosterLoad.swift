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

    package var isLoadingOrFailed: Bool {
        switch self {
        case .loading, .failed: true
        case .idle, .done: false
        }
    }

    package var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// About you's line under the pickers while the load runs.
    package var stillLoadingText: String? {
        guard case let .loading(fetched, saved) = self else { return nil }
        return saved == 0 ? "Still loading people — \(fetched)" : "Still loading people — \(saved) of \(fetched)"
    }

    /// The Slack card's progress line; nil when there is nothing to say.
    /// While users.list pages arrive Slack gives no total, so the count
    /// stands alone; saving knows its total.
    package var progressText: String? {
        switch self {
        case .idle: nil
        case let .loading(fetched, saved): saved == 0
            ? "Loading people… \(fetched)"
            : "Loading people… \(saved) of \(fetched)"
        case .done(let count): "\(count) people loaded"
        case .failed(let reason): "Couldn't load people: \(reason)"
        }
    }
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
    /// The account of the last run, which Retry loads again.
    package private(set) var accountID: Int?

    @ObservationIgnored private let run: Run
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Bumped per run and by `stop()`: a cancelled run's late lines and exit
    /// never touch `state`.
    @ObservationIgnored private var generation = 0

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
        generation += 1
        let runGeneration = generation
        self.accountID = accountID
        state = .loading(fetched: 0, saved: 0)
        task = Task { [weak self, run] in
            var lastTotal = 0
            var lastError: String?
            let decoder = JSONDecoder()
            let result = await run(accountID) { [weak self] line in
                guard let self, runGeneration == generation,
                      let progress = try? decoder.decode(SyncProgressData.self, from: Data(line.utf8)) else { return }
                if let error = progress.error, !error.isEmpty {
                    lastError = error
                    return
                }
                lastTotal = progress.userProfilesTotal
                state = .loading(fetched: progress.userProfilesTotal, saved: progress.userProfilesDone)
            }
            guard let self, runGeneration == generation else { return }
            if result.exitCode == 0 {
                state = .done(count: lastTotal)
            } else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                state = .failed(lastError ?? (stderr.isEmpty ? "exit code \(result.exitCode)" : String(stderr.prefix(300))))
            }
        }
        return true
    }

    /// Starts again for the account whose load failed.
    @discardableResult
    package func retry() -> Bool {
        guard case .failed = state, let accountID else { return false }
        return start(accountID: accountID)
    }

    /// Waits for the current run, if any.
    package func waitForCompletion() async {
        await task?.value
    }

    /// Ends a running load (app quit); a later `start` begins again.
    package func stop() {
        generation += 1
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
