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

    func title(sessionID: Int64) async throws -> TerminalTitleResult {
        let data = try await runner.run(args: ["terminal", "title", String(sessionID), "--json"])
        return try JSONDecoder().decode(TerminalTitleResult.self, from: data)
    }
}
