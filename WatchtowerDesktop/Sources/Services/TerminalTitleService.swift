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
    /// the owner's own session, or of a session a run the owner triggered
    /// started (Run now, a button, a reply), is owner work (background AI
    /// consent spec §2.2); one of a schedule, event, sync or catch-up run's
    /// session is background (`TerminalSession.isBackgroundRunSession`).
    static func origin(for session: TerminalSession) -> CLIOrigin {
        session.isBackgroundRunSession ? .background : .owner
    }

    func title(session: TerminalSession) async throws -> TerminalTitleResult {
        let args = ["terminal", "title", String(session.id), "--json"]
        let data = try await runner.runModel(args: args, origin: Self.origin(for: session))
        return try JSONDecoder().decode(TerminalTitleResult.self, from: data)
    }
}
