import Foundation
import GRDB

/// A custom track card's watch controls (instruction, Collecting, Scan
/// from), driven through its watch recipe. The instruction, Collecting and
/// the scan go through `controls` (C1's `CustomTrackControlling` seam), so
/// this model never writes a `tracks` column itself; `load` and Start
/// Watching call the CLI directly (`show --json`'s `watch` block, `tracks
/// start`, after which the track row is read again). One write at a time: a
/// press while another runs is ignored.
@MainActor
@Observable
package final class WatchTrackControls {
    package static let savedNote = "Saved"
    /// A scan is queued for the next sync (`automations run --since`'s `at_next_sync`).
    package static let nextSyncNote = "Runs at the next sync"
    package static let emptyInstruction = "Say what to watch for first."
    /// **All history**'s Scan from: the epoch, as the legacy scan's
    /// `RunForTrackSince` documents for "all history". "Since last check" is nil.
    package static let allHistory = Date(timeIntervalSince1970: 0)

    package private(set) var track: Track
    package var instructionDraft: String
    /// The card may rewrite the instruction; false once the recipe was
    /// changed in the chat (`show --json` `watch.template_shaped`).
    package private(set) var templateShaped = true
    package private(set) var collecting: Bool
    /// The **Scan from** date; nil = since the last check.
    package var scanFrom: Date?
    /// The last write's outcome in words ("Saved", "Runs at the next sync").
    package private(set) var note: String?
    /// The last call's failure, the CLI's refusal text when it gave one.
    package private(set) var error: String?
    package private(set) var isWorking = false

    /// The track has a watch recipe: false = the card offers **Start Watching**.
    package var isBound: Bool { track.automationID != nil }

    @ObservationIgnored private let cli: AutomationsCLI
    @ObservationIgnored private let controls: any CustomTrackControlling
    /// Where the track row is read again after Start Watching binds it.
    @ObservationIgnored private let reader: any DatabaseReader

    package init(
        track: Track,
        cli: AutomationsCLI,
        controls: any CustomTrackControlling,
        reader: any DatabaseReader
    ) {
        self.track = track
        self.cli = cli
        self.controls = controls
        self.reader = reader
        instructionDraft = track.instruction
        collecting = track.enabled
    }

    /// Reads the watch's instruction and whether the card may change it.
    package func load() async {
        guard let automationID = track.automationID else { return }
        do {
            guard let watch = try await cli.showWatch(automationID) else { return }
            instructionDraft = watch.instruction
            templateShaped = watch.templateShaped
            error = nil
        } catch {
            self.error = AutomationsViewModel.message(for: error)
        }
    }

    /// Saves the draft; a refusal keeps it, so the owner's text is not lost.
    /// An empty draft is not sent: `error` says why.
    package func saveInstruction() async {
        guard isBound, !isWorking else { return }
        let text = instructionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            note = nil
            error = Self.emptyInstruction
            return
        }
        let track = track
        await perform {
            try await self.controls.saveInstruction(track, text: text)
            self.note = Self.savedNote
        }
    }

    package func setCollecting(_ on: Bool) async {
        guard isBound else { return }
        let track = track
        await perform {
            try await self.controls.setCollecting(track, on: on)
            self.collecting = on
        }
    }

    /// Queues a scan from `scanFrom` (nil = since the last check) for the next sync.
    package func scan() async {
        guard isBound else { return }
        let (track, from) = (track, scanFrom)
        await perform {
            try await self.controls.scan(track, from: from)
            self.note = Self.nextSyncNote
        }
    }

    /// Binds an unbound track to a new watch recipe, reads the track row
    /// again (now carrying `automation_id`), then reads the watch.
    package func startWatching() async {
        guard !isBound else { return }
        let id = track.id
        let reader = reader
        await perform {
            _ = try await self.cli.trackStart(id)
            guard let fresh = try await reader.read({ try TrackQueries.fetchByID($0, id: id) }) else {
                throw RowNotFoundError(kind: "track", id: id)
            }
            self.track = fresh
        }
        if isBound { await load() }
    }

    private func perform(_ body: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        note = nil
        error = nil
        do {
            try await body()
        } catch {
            self.error = AutomationsViewModel.message(for: error)
        }
    }
}
