import Foundation
import GRDB

/// C3's custom-track controls: a track bound to a watch recipe
/// (`automationID != nil`) is driven through the recipe's CLI verbs, and the
/// `tracks` row's `enabled` and `instruction` are never written from Swift —
/// the CLI writes the instruction mirror and the `automations` → `tracks`
/// SQL trigger mirrors `enabled`. An unbound track (a legacy custom track
/// while the custom-tracks move has not finished) keeps C1's direct controls
/// for every method.
@MainActor package final class RecipeCustomTrackControls: CustomTrackControlling {
    /// The text of Go `db.ErrAutomationNotFound`, which `automations delete`
    /// prints for a recipe that is already gone.
    nonisolated static let automationNotFound = "automation not found"

    private let cli: AutomationsCLI
    private let direct: DirectCustomTrackControls

    package init(cli: AutomationsCLI, direct: DirectCustomTrackControls) {
        self.cli = cli
        self.direct = direct
    }

    /// `tracks instruction <id> --text-file …`.
    package func saveInstruction(_ track: Track, text: String) async throws {
        guard track.automationID != nil else { return try await direct.saveInstruction(track, text: text) }
        try await cli.trackInstruction(track.id, text: text)
    }

    /// `automations enable|disable <automation>`.
    package func setCollecting(_ track: Track, on: Bool) async throws {
        guard let automationID = track.automationID else { return try await direct.setCollecting(track, on: on) }
        try await cli.setEnabled(automationID, on)
    }

    /// `automations run <automation> [--since …] --json`: queued for the next sync.
    package func scan(_ track: Track, from: Date?) async throws {
        guard let automationID = track.automationID else { return try await direct.scan(track, from: from) }
        _ = try await cli.runSince(automationID, since: from)
    }

    /// Bound: the recipe off first, so a dismissed track never keeps spending
    /// tokens, then the track dismissed.
    package func stopWatching(_ track: Track) async throws {
        guard let automationID = track.automationID else { return try await direct.stopWatching(track) }
        try await cli.setEnabled(automationID, false)
        let id = track.id
        try await direct.dbPool.write { try TrackQueries.dismiss($0, id: id) }
    }

    /// Bound: the track restored, then its recipe on.
    package func resumeWatching(_ track: Track) async throws {
        guard let automationID = track.automationID else { return try await direct.resumeWatching(track) }
        let id = track.id
        try await direct.dbPool.write { try TrackQueries.restore($0, id: id) }
        try await cli.setEnabled(automationID, true)
    }

    /// Bound: the recipe deleted first (the SQL trigger unbinds the track) —
    /// one already gone counts as deleted — then the track and its events.
    package func delete(_ track: Track) async throws {
        if let automationID = track.automationID {
            do {
                try await cli.delete(automationID)
            } catch let CLIRunnerError.nonZeroExit(_, stderr) where stderr.contains(Self.automationNotFound) {
                // Removed elsewhere since this track was read: nothing left to delete.
            }
        }
        try await direct.delete(track)
    }
}
