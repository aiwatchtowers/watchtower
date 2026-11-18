import Foundation
import WatchtowerCore

/// `watchtower terminal title <id> --json` envelope. `written == false`: no
/// owner message yet, or the row is not auto-titled — nothing changed.
struct TerminalTitleResult: Decodable, Equatable {
    let title: String
    let written: Bool
}

/// Asks the CLI for an AI title of an auto-titled `claude` session (spec §5).
/// The CLI reads the transcript and writes the row; this only runs it.
struct TerminalTitleService {
    let runner: any CLIRunnerProtocol

    /// The origin follows the session, not the poll that asks: a title of
    /// the owner's own session is owner work (background AI consent spec
    /// §2.2), one of a session an automation run started is background.
    static func origin(for session: TerminalSession) -> CLIOrigin {
        session.automationRunID == nil ? .owner : .background
    }

    func title(session: TerminalSession) async throws -> TerminalTitleResult {
        let args = ["terminal", "title", String(session.id), "--json"]
        let data = try await runner.runModel(args: args, origin: Self.origin(for: session))
        return try JSONDecoder().decode(TerminalTitleResult.self, from: data)
    }
}
