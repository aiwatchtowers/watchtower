import Foundation

/// App-wide registry of in-flight custom-track scans. A scan runs for minutes as
/// a CLI subprocess; its progress state used to live only in the per-view
/// timeline VM, so navigating away from the track detail hid any indication it
/// was still running. Routing scans through this shared, `AppState`-held center
/// lets the list and sidebar show a persistent "scanning" indicator that
/// survives navigation.
@MainActor
@Observable
final class TrackScanCenter {
    /// Track IDs with a scan currently in flight.
    private(set) var running: Set<Int> = []
    /// Last completed-scan note per track (result or error), so the detail can
    /// still surface the outcome if the user was away when it finished.
    private(set) var note: [Int: String] = [:]

    func isRunning(_ trackID: Int) -> Bool { running.contains(trackID) }

    /// Marks a scan as started. Clears any stale note for the track.
    func begin(_ trackID: Int) {
        running.insert(trackID)
        note[trackID] = nil
    }

    /// Marks a scan as finished, optionally recording a result/error note.
    func finish(_ trackID: Int, note text: String?) {
        running.remove(trackID)
        if let text { note[trackID] = text }
    }
}
