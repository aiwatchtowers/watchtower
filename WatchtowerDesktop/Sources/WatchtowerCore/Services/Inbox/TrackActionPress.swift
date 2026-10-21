import Foundation

/// The press of a track event's proposed change (Inbox card or the track /
/// target Activity feed): one `watchtower actions propose --approve` that
/// proposes `apply_track_action` on the `inbox` surface and applies it through
/// the registry, so the change is audited like every other action and the
/// event's claim is taken in Go. The Desktop writes nothing itself.
///
/// The launch goes through the runner (`ProcessCLIRunner` registers the exact
/// argv with `OwnerConfirmGrants`), so the CLI's owner confirmation is
/// answered without a window — the owner already pressed the button.
package struct TrackActionPress {
    private let runner: any CLIRunnerProtocol

    package init(runner: any CLIRunnerProtocol) {
        self.runner = runner
    }

    package static func arguments(eventID: Int) -> [String] {
        [
            "actions", "propose", "--tool", "apply_track_action", "--surface", "inbox",
            "--context-type", "track_event", "--context-id", String(eventID),
            "--args", "{\"event_id\":\(eventID)}", "--approve", "--json"
        ]
    }

    package struct Refusal: LocalizedError, Equatable {
        package let message: String
        package var errorDescription: String? { message }
    }

    /// Throws the CLI's own refusal text: a non-zero exit (stderr), an
    /// envelope `error`, or an `ok`/`applied_ok` of false without one.
    package func press(eventID: Int) async throws {
        let data: Data
        do {
            data = try await runner.run(args: Self.arguments(eventID: eventID))
        } catch let CLIRunnerError.nonZeroExit(code, stderr) {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw Refusal(message: text.isEmpty ? "watchtower exited with code \(code)" : text)
        }
        guard let env = try? JSONDecoder().decode(AgentActionFeed.Envelope.self, from: data) else {
            throw Refusal(message: "watchtower returned an unreadable answer.")
        }
        if let err = env.error, !err.isEmpty { throw Refusal(message: err) }
        if !env.ok || !env.appliedOK {
            throw Refusal(message: "The change was not applied.")
        }
    }
}
