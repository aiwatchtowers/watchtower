import Foundation

/// Why the quiet-threads plan could not be read. The Desktop never retries
/// one by itself.
package enum TracksBulkCLIError: Error, Equatable, LocalizedError {
    /// No `watchtower` binary.
    case cliUnavailable
    /// The CLI refused or failed; its message (the last stderr line), or the
    /// timeout message.
    case refused(String)
    /// The CLI answered without the pinned JSON: never taken as a plan.
    case unexpectedAnswer

    package var errorDescription: String? {
        switch self {
        case .cliUnavailable: "The watchtower CLI isn't available"
        case let .refused(message): message
        case .unexpectedAnswer: "Unexpected answer from watchtower"
        }
    }
}

/// The Inbox's bulk close of Track my threads: `watchtower tracks dismiss`
/// (cmd/tracks.go), a dry run that plans the quiet threads and an apply of
/// the confirmed ids. Both read the pinned `--json` keys of the last stdout
/// line; the apply never throws, every outcome is an `InboxBulkResult`.
package struct TracksBulkCLI {
    /// Both calls give up after this many seconds.
    package static let timeout: TimeInterval = 60
    /// A timed-out call: the outcome is unknown, so the owner reads this
    /// rather than a count.
    package static let timeoutMessage = "watchtower took too long to answer"

    private let runner: (any CLIRunnerProtocol)?

    /// `runner` nil = no binary was found (`ProcessCLIRunner.makeDefault()`).
    package init(runner: (any CLIRunnerProtocol)?) {
        self.runner = runner
    }

    package static func dryRunArgs(quietDays: Int) -> [String] {
        ["tracks", "dismiss", "--quiet-days", String(quietDays), "--dry-run", "--json"]
    }

    package static func dismissArgs(ids: [String]) -> [String] {
        ["tracks", "dismiss", "--ids", ids.joined(separator: ","), "--json"]
    }

    /// The threads quiet for `days` days, as the dry run lists them.
    package func planQuiet(days: Int) async throws -> InboxBulkPlan {
        let result: CLICapturedResult
        do {
            result = try await capture(Self.dryRunArgs(quietDays: days))
        } catch let error as TracksBulkCLIError {
            throw error
        } catch {
            throw TracksBulkCLIError.refused(error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            throw TracksBulkCLIError.refused(Self.failureMessage(result))
        }
        guard let plan: Plan = Self.decodeLastLine(result.stdout) else {
            throw TracksBulkCLIError.unexpectedAnswer
        }
        return InboxBulkPlan(ids: plan.ids.map(String.init), count: plan.count)
    }

    /// Dismisses `ids`. A write error part-way is `.partial` when something
    /// was dismissed, `.failed` when nothing was.
    package func dismiss(ids: [String]) async -> InboxBulkResult {
        let result: CLICapturedResult
        do {
            result = try await capture(Self.dismissArgs(ids: ids))
        } catch {
            return .failed(error.localizedDescription)
        }
        if result.exitCode == 0 {
            guard let done: Done = Self.decodeLastLine(result.stdout) else {
                return .failed(TracksBulkCLIError.unexpectedAnswer.localizedDescription)
            }
            return .done(count: done.dismissed, skipped: done.skipped)
        }
        if result.exitCode != Self.timeoutExitCode, let partial: Partial = Self.decodeLastLine(result.stdout) {
            return partial.dismissed > 0
                ? .partial(done: partial.dismissed, of: partial.of, error: partial.error)
                : .failed(partial.error)
        }
        return .failed(Self.failureMessage(result))
    }

    // MARK: - Running

    /// `CLIRunnerError.nonZeroExit`'s code for a call past its deadline.
    private static let timeoutExitCode: Int32 = -1

    /// One call, with stdout kept on a non-zero exit (the partial envelope).
    /// A deadline the runner throws comes back as a `timeoutExitCode` result,
    /// as the protocol's default `capture` hands it; the other runner
    /// failures throw a `TracksBulkCLIError`.
    private func capture(_ args: [String]) async throws -> CLICapturedResult {
        guard let runner else { throw TracksBulkCLIError.cliUnavailable }
        do {
            return try await runner.capture(args: args, timeout: Self.timeout)
        } catch let CLIRunnerError.nonZeroExit(code, stderr) {
            return CLICapturedResult(stdout: Data(), exitCode: code, stderr: stderr)
        } catch CLIRunnerError.binaryNotFound {
            throw TracksBulkCLIError.cliUnavailable
        }
    }

    /// What a failed call says: the timeout message, else the CLI's last
    /// stderr line, else its exit code.
    private static func failureMessage(_ result: CLICapturedResult) -> String {
        if result.exitCode == timeoutExitCode { return timeoutMessage }
        let message = InboxFoldersCLI.lastLine(result.stderr)
        return message.isEmpty ? "watchtower exited with code \(result.exitCode)" : message
    }

    /// The last non-empty stdout line decoded as `T`; nil when it is not one
    /// with every pinned key.
    private static func decodeLastLine<T: Decodable>(_ data: Data) -> T? {
        guard let text = String(bytes: data, encoding: .utf8) else { return nil }
        let line = InboxFoldersCLI.lastLine(text)
        guard !line.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: Data(line.utf8))
    }

    // MARK: - Pinned `--json` keys

    /// `--dry-run --json`: `count`, `ids` (integers).
    private struct Plan: Decodable {
        let count: Int
        let ids: [Int64]
    }

    /// `--ids … --json`: `dismissed`, `skipped`, `ids`.
    private struct Done: Decodable {
        let dismissed: Int
        let skipped: Int
        let ids: [Int64]
    }

    /// A write error (exit 1): `dismissed`, `of`, `error`.
    private struct Partial: Decodable {
        let dismissed: Int
        let of: Int
        let error: String
    }
}
