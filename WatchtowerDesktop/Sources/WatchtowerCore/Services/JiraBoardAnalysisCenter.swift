import Foundation

/// App-wide registry for `jira boards analyze` runs. Board analysis is a
/// strong-tier AI call that takes minutes, so — like `JiraBoardSyncManager` next
/// to it — it lives beyond the view lifecycle: the run, its spinner and its
/// error survive the user leaving the board screen ("начал → ушёл → вернулся").
/// Owning it in the view's `@State` meant a failure that landed after the screen
/// was gone was swallowed, and the post-run refresh went to a discarded view.
///
/// Not single-slot (unlike the sync manager): runs are keyed by board, so two
/// sites' boards can analyze at once, while a second click on a board already
/// analyzing is a no-op.
@MainActor
@Observable
package final class JiraBoardAnalysisCenter {
    package static let shared = JiraBoardAnalysisCenter()

    /// Boards with a run in flight, keyed by `JiraBoard.rowID` — raw board ids
    /// collide across connected sites (migration 00049).
    package private(set) var analyzing: Set<String> = []
    /// Last failure per board, kept until the next run for that board starts.
    package private(set) var errors: [String: String] = [:]
    /// Bumped once per successful run. Screens watch it to reload the board
    /// from SQLite: the profile is written by the CLI subprocess, and GRDB's
    /// `ValueObservation` cannot see another process's write.
    package private(set) var completedRuns = 0

    /// In-flight tasks by rowID. Internal (not private) so tests can await them.
    var tasks: [String: Task<Void, Never>] = [:]

    package init() {}

    // MARK: - Reads

    package func isAnalyzing(_ board: JiraBoard) -> Bool {
        analyzing.contains(board.rowID)
    }

    package func error(for board: JiraBoard) -> String? {
        errors[board.rowID]
    }

    package func clearError(for board: JiraBoard) {
        errors[board.rowID] = nil
    }

    func task(for board: JiraBoard) -> Task<Void, Never>? {
        tasks[board.rowID]
    }

    // MARK: - Run

    /// Starts `jira boards analyze --force` for `board`. A no-op while that same
    /// board is already analyzing. `runner` defaults to the real CLI; passing
    /// nil (no binary resolved) records the failure instead of running.
    package func start(
        board: JiraBoard,
        runner: CLIRunnerProtocol? = ProcessCLIRunner.makeDefault()
    ) {
        let key = board.rowID
        guard !analyzing.contains(key) else { return }

        errors[key] = nil
        guard let runner else {
            errors[key] = "Watchtower CLI not found"
            return
        }

        analyzing.insert(key)
        let arguments = [
            "jira", "--account", String(board.accountID),
            "boards", "analyze", "--force", String(board.id)
        ]

        tasks[key] = Task { [weak self] in
            var failure: String?
            do {
                _ = try await runner.run(args: arguments)
            } catch {
                failure = Self.message(for: error)
            }

            guard let self else { return }
            analyzing.remove(key)
            tasks[key] = nil
            if let failure {
                errors[key] = failure
            } else {
                completedRuns += 1
            }
        }
    }

    /// User-facing text for a failed run: the CLI's own stderr when it said
    /// something, else a generic fallback.
    static func message(for error: Error) -> String {
        guard let cliError = error as? CLIRunnerError else {
            if error is CancellationError { return "Analysis cancelled" }
            return "Analysis failed"
        }
        switch cliError {
        case .binaryNotFound:
            return "Watchtower CLI not found"
        case .launchFailed:
            return "Failed to launch CLI"
        case .nonZeroExit(_, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Analysis failed" : String(trimmed.prefix(200))
        }
    }
}
