import Foundation

/// The status bar's and tray's history backfill line.
package enum BackfillProgress {
    private static let day: Double = 86_400

    /// nil when nothing is loading (no rows, or every row done/off).
    package static func line(_ rows: [BackfillRow]) -> String? {
        let active = rows.filter { $0.status == "running" || $0.status == "paused" }
        guard !active.isEmpty else { return nil }
        if active.contains(where: { $0.waiting == "plan_limit" }) {
            return "Loading history paused — Claude plan limit"
        }
        let total = active.reduce(0) { $0 + Int((($1.upperTS - $1.floorTS) / day).rounded()) }
        let loaded = active.reduce(0) { $0 + Int((($1.upperTS - $1.reachedTS) / day).rounded()) }
        return "Loading history: \(loaded) of \(total) days"
    }
}
