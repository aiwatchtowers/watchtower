import Foundation
import WatchtowerInterface

/// The one seam for a custom track's card controls and Stop watching. The unbound
/// controls write `tracks` through the tower; C3's drive a bound track's watch recipe,
/// without touching the pane or `ActionStripViewModel`.
@MainActor package protocol CustomTrackControlling: AnyObject {
    func saveInstruction(_ track: Track, text: String) async throws
    func setCollecting(_ track: Track, on: Bool) async throws
    /// Scans now: from `from`, or — nil — from the track's own watermark
    /// ("Since last check").
    func scan(_ track: Track, from: Date?) async throws
    /// Dismisses the track and turns its collection off (R4), so the daemon stops spending tokens on it.
    func stopWatching(_ track: Track) async throws
    /// Undoes Stop watching: restores the track and turns its collection back on.
    func resumeWatching(_ track: Track) async throws
    /// Deletes the track and its events for good.
    func delete(_ track: Track) async throws
}

/// The unbound controls: the `tracks` row through the `tracks.*` tower
/// commands (Go writes it, #1170 Task 12), a scan through `watchtower tracks
/// scan`. Stop watching and its undo are `tracks.stop`/`tracks.restore`,
/// which turn the collection off and on in the same write — through the
/// track's recipe when one is bound — so `RecipeCustomTrackControls` sends
/// them here too.
@MainActor package final class DirectCustomTrackControls: CustomTrackControlling {
    private let tower: (any TowerSending)?
    private let scanService: TrackScanService

    /// `tower` nil: made without the app's tower; every write fails with the daemon's sentence.
    package init(tower: (any TowerSending)?, scanService: TrackScanService) {
        self.tower = tower
        self.scanService = scanService
    }

    package func saveInstruction(_ track: Track, text: String) async throws {
        let id = Int64(track.id)
        let _: ActResult = try await send(.tracksInstruction) {
            TrackInstructionRequest(requestID: $0, id: id, instruction: text)
        }
    }

    package func setCollecting(_ track: Track, on: Bool) async throws {
        let id = Int64(track.id)
        let _: ActResult = try await send(.tracksEnabled) { TrackEnabledRequest(requestID: $0, id: id, enabled: on) }
    }

    package func scan(_ track: Track, from: Date?) async throws {
        _ = try await scanService.run(trackID: track.id, since: from.map(AutomationDates.format))
    }

    package func stopWatching(_ track: Track) async throws {
        let id = Int64(track.id)
        let _: ActResult = try await send(.tracksStop) { ScreenIDsRequest(requestID: $0, iDs: [id]) }
    }

    package func resumeWatching(_ track: Track) async throws {
        let id = Int64(track.id)
        let _: ActResult = try await send(.tracksRestore) { ScreenIDRequest(requestID: $0, id: id) }
    }

    package func delete(_ track: Track) async throws {
        let id = Int64(track.id)
        let _: ActResult = try await send(.tracksDelete) { ScreenIDRequest(requestID: $0, id: id) }
    }

    private func send<Resp: Decodable & Sendable, Params: Encodable & Sendable>(
        _ command: TowerCommand, _ params: (String) -> Params
    ) async throws -> Resp {
        guard let tower else { throw TowerWriteError(TowerText.daemonDown) }
        return try await tower.perform(command, params)
    }
}
