import Foundation

/// Why a bulk dry run gave no plan, or why a press failed before the CLI
/// answered. Texts as `InboxFoldersCLIError`'s.
package enum InboxBulkCLIError: Error, Equatable, LocalizedError {
    /// No `watchtower` binary.
    case cliUnavailable
    /// The CLI refused: the `error` of its exit-1 object, else its stderr's
    /// last line.
    case refused(String)
    /// The CLI answered without the pinned JSON: never taken as success.
    case unexpectedAnswer

    package var errorDescription: String? {
        switch self {
        case .cliUnavailable: "The watchtower CLI isn't available"
        case let .refused(message): message
        case .unexpectedAnswer: "Unexpected answer from watchtower"
        }
    }
}

/// The Desktop's bulk "mark done" path: `watchtower inbox resolve`'s owner
/// forms (cmd/inbox.go). A dry run names the open items a filter matches;
/// the press resolves exactly those ids, never more. Every call is a
/// `capture`, so the exit-1 `{"resolved","of","error"}` line is read.
package struct InboxBulkCLI {
    package enum Operation: Equatable {
        case planSender(String)
        case planOlderPeople(days: Int)
        case resolve(ids: [String])
    }

    /// How long one call may take before the child is terminated.
    static let timeout: TimeInterval = 120

    private let runner: (any CLIRunnerProtocol)?

    /// `runner` nil = no binary was found (`ProcessCLIRunner.makeDefault()`).
    package init(runner: (any CLIRunnerProtocol)?) {
        self.runner = runner
    }

    package static func args(_ operation: Operation) -> [String] {
        switch operation {
        case let .planSender(address):
            return ["inbox", "resolve", "--dry-run", "--json", "--sender", address, "--trigger", "email_received"]
        case let .planOlderPeople(days):
            return ["inbox", "resolve", "--dry-run", "--json", "--older-than", "\(days)d", "--people"]
        case let .resolve(ids):
            return ["inbox", "resolve", "--ids", ids.joined(separator: ","), "--json"]
        }
    }

    /// The open mail items from `address` (a dry run: nothing written).
    package func planSender(_ address: String) async throws -> InboxBulkPlan {
        try await plan(.planSender(address))
    }

    /// The open people items `days` or more old (a dry run: nothing written).
    package func planOlderPeople(days: Int = 7) async throws -> InboxBulkPlan {
        try await plan(.planOlderPeople(days: days))
    }

    /// Resolves exactly `ids`; never throws, every failure is `.failed`.
    /// No ids runs nothing.
    package func resolve(ids: [String]) async -> InboxBulkResult {
        if ids.isEmpty { return .done(count: 0, skipped: 0) }
        let result: CLICapturedResult
        do {
            result = try await capture(.resolve(ids: ids))
        } catch {
            return .failed(error.localizedDescription)
        }
        if result.exitCode != 0 {
            guard let failure: Failure = Self.lastLine(result.stdout) else {
                return .failed(Self.refusal(result).localizedDescription)
            }
            return failure.resolved > 0
                ? .partial(done: failure.resolved, of: failure.of, error: failure.error)
                : .failed(failure.error)
        }
        guard let done: Resolved = Self.lastLine(result.stdout), done.resolved == done.ids.count else {
            return .failed(InboxBulkCLIError.unexpectedAnswer.localizedDescription)
        }
        return .done(count: done.resolved, skipped: done.skipped)
    }

    private func plan(_ operation: Operation) async throws -> InboxBulkPlan {
        let result = try await capture(operation)
        if result.exitCode != 0 {
            if let failure: Failure = Self.lastLine(result.stdout) { throw InboxBulkCLIError.refused(failure.error) }
            throw Self.refusal(result)
        }
        guard let plan: Plan = Self.lastLine(result.stdout), plan.count == plan.ids.count else {
            throw InboxBulkCLIError.unexpectedAnswer
        }
        return InboxBulkPlan(ids: plan.ids, count: plan.count)
    }

    private func capture(_ operation: Operation) async throws -> CLICapturedResult {
        guard let runner else { throw InboxBulkCLIError.cliUnavailable }
        do {
            return try await runner.capture(args: Self.args(operation), timeout: Self.timeout)
        } catch CLIRunnerError.binaryNotFound {
            throw InboxBulkCLIError.cliUnavailable
        } catch {
            throw InboxBulkCLIError.refused(error.localizedDescription)
        }
    }

    /// A non-zero exit without the error object: the stderr's last line.
    private static func refusal(_ result: CLICapturedResult) -> InboxBulkCLIError {
        let message = InboxFoldersCLI.lastLine(result.stderr)
        return .refused(message.isEmpty ? "watchtower exited with code \(result.exitCode)" : message)
    }

    /// The last non-empty stdout line decoded as `T`; nil when it is not one
    /// with every pinned key.
    private static func lastLine<T: Decodable>(_ data: Data) -> T? {
        try? InboxFoldersCLI.decodeLastLine(data) as T
    }

    // MARK: - The pinned `--json` keys

    /// Dry run: `count`, `ids`.
    private struct Plan: Decodable {
        let count: Int
        let ids: [String]
    }

    /// `--ids`: `resolved`, `skipped`, `ids` (the ones resolved).
    private struct Resolved: Decodable {
        let resolved: Int
        let skipped: Int
        let ids: [String]
    }

    /// Any failure (exit 1): `resolved`, `of`, `error`.
    private struct Failure: Decodable {
        let resolved: Int
        let of: Int
        let error: String
    }
}
