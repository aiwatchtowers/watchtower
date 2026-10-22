import Foundation
import GRDB

/// The one seam for a custom track's card controls and Stop watching. C1 writes `tracks`
/// directly; C3 swaps in an implementation that drives the track's watch recipe, without
/// touching the pane or `ActionStripViewModel`.
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

/// C1's controls: the `tracks` row through `TrackQueries`, a scan through `watchtower tracks scan`.
@MainActor package final class DirectCustomTrackControls: CustomTrackControlling {
    private let dbPool: DatabasePool
    private let scanService: TrackScanService

    package init(dbPool: DatabasePool, scanService: TrackScanService) {
        self.dbPool = dbPool
        self.scanService = scanService
    }

    package func saveInstruction(_ track: Track, text: String) async throws {
        let id = track.id
        try await dbPool.write { try TrackQueries.updateInstruction($0, id: id, instruction: text) }
    }

    package func setCollecting(_ track: Track, on: Bool) async throws {
        let id = track.id
        try await dbPool.write { try TrackQueries.setEnabled($0, id: id, enabled: on) }
    }

    package func scan(_ track: Track, from: Date?) async throws {
        _ = try await scanService.run(trackID: track.id, since: from.map(AutomationDates.format))
    }

    package func stopWatching(_ track: Track) async throws {
        let id = track.id
        try await dbPool.write { db in
            try TrackQueries.setEnabled(db, id: id, enabled: false)
            try TrackQueries.dismiss(db, id: id)
        }
    }

    package func resumeWatching(_ track: Track) async throws {
        let id = track.id
        try await dbPool.write { db in
            try TrackQueries.restore(db, id: id)
            try TrackQueries.setEnabled(db, id: id, enabled: true)
        }
    }

    package func delete(_ track: Track) async throws {
        let id = track.id
        try await dbPool.write { try TrackQueries.delete($0, id: id) }
    }
}
