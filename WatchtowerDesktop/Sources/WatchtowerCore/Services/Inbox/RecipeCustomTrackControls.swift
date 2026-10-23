import Foundation
import GRDB

/// C3's custom-track controls: a track bound to a watch recipe
/// (`automationID != nil`) is driven through the recipe's CLI verbs, and the
/// `tracks` row's `enabled` and `instruction` are never written from Swift —
/// the CLI writes the instruction mirror and the `automations` → `tracks`
/// SQL trigger mirrors `enabled`. An unbound track only stops, resumes and
/// deletes through C1's direct controls; its card offers **Start Watching**
/// instead of the other controls, so those throw `NotWatched`.
@MainActor package final class RecipeCustomTrackControls: CustomTrackControlling {
    /// A control the card does not offer for an unbound track.
    package struct NotWatched: LocalizedError, Equatable {
        package let trackID: Int

        package var errorDescription: String? {
            "Track #\(trackID) is not watched yet. Press Start Watching first."
        }
    }

    private let cli: AutomationsCLI
    private let direct: DirectCustomTrackControls

    package init(cli: AutomationsCLI, direct: DirectCustomTrackControls) {
        self.cli = cli
        self.direct = direct
    }

    /// `tracks instruction <id> --text-file …`.
    package func saveInstruction(_ track: Track, text: String) async throws {
        _ = try watch(track)
        try await cli.trackInstruction(track.id, text: text)
    }

    /// `automations enable|disable <automation>`.
    package func setCollecting(_ track: Track, on: Bool) async throws {
        try await cli.setEnabled(watch(track), on)
    }

    /// `automations run <automation> [--since …] --json`: queued for the next sync.
    package func scan(_ track: Track, from: Date?) async throws {
        _ = try await cli.runSince(watch(track), since: from)
    }

    /// Bound: the recipe off first, so a dismissed track never keeps spending
    /// tokens, then the track dismissed. Unbound: C1's direct write.
    package func stopWatching(_ track: Track) async throws {
        guard let automationID = track.automationID else { return try await direct.stopWatching(track) }
        try await cli.setEnabled(automationID, false)
        let id = track.id
        try await direct.dbPool.write { try TrackQueries.dismiss($0, id: id) }
    }

    /// Bound: the track restored, then its recipe on. Unbound: C1's direct write.
    package func resumeWatching(_ track: Track) async throws {
        guard let automationID = track.automationID else { return try await direct.resumeWatching(track) }
        let id = track.id
        try await direct.dbPool.write { try TrackQueries.restore($0, id: id) }
        try await cli.setEnabled(automationID, true)
    }

    /// Bound: the recipe deleted first (the SQL trigger unbinds the track),
    /// then the track and its events.
    package func delete(_ track: Track) async throws {
        if let automationID = track.automationID {
            try await cli.delete(automationID)
        }
        try await direct.delete(track)
    }

    private func watch(_ track: Track) throws -> Int64 {
        guard let automationID = track.automationID else { throw NotWatched(trackID: track.id) }
        return automationID
    }
}
