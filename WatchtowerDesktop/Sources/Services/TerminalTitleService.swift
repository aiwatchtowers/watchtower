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
/// Background origin: the 2-minute title poll and the switch-away refresh
/// start it, never a request of the owner's, so it waits for the owner's
/// background-AI answer like any other background run (#1886).
struct TerminalTitleService {
    let runner: any CLIRunnerProtocol

    func title(sessionID: Int64) async throws -> TerminalTitleResult {
        let data = try await runner.runModel(args: ["terminal", "title", String(sessionID), "--json"], origin: .background)
        return try JSONDecoder().decode(TerminalTitleResult.self, from: data)
    }
}
