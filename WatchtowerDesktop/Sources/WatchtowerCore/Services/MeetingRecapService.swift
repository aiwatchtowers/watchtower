import Foundation

/// Bridges the Desktop app to `watchtower meeting-prep recap --json`.
/// CLI is the sole writer to `meeting_recaps`; on success the row is upserted
/// before returning. Caller refetches via `MeetingRecapQueries.fetch` to get
/// authoritative content + timestamps.
package struct MeetingRecapService {
    package let runner: CLIRunnerProtocol

    package init(runner: CLIRunnerProtocol) {
        self.runner = runner
    }

    package func generate(eventID: String, text: String) async throws {
        // The text travels on stdin (`--text-file -`, #604 S6): off argv
        // (ARG_MAX, `ps`) and never in a temp file.
        let args = [
            "meeting-prep", "recap",
            "--event-id", eventID,
            "--text-file", "-",
            "--json"
        ]
        // Discard stdout — caller refetches from DB.
        _ = try await runner.run(args: args, stdin: Data(text.utf8))
    }
}
