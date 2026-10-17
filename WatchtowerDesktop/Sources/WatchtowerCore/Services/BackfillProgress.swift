import Foundation

/// The status bar's and tray's history backfill line.
package enum BackfillProgress {
    private static let day: Double = 86_400

    /// nil when nothing is loading (no rows, or every row done/off). The plan
    /// limit copy wins; otherwise only running rows count, and rows that are
    /// all paused (a revoked account) ask for a reconnect (R22). When every
    /// running row is held by a transient failure (offline, a service down),
    /// the line says it waits and retries (#580).
    package static func line(_ rows: [BackfillRow]) -> String? {
        let active = rows.filter { $0.status == "running" || $0.status == "paused" }
        guard !active.isEmpty else { return nil }
        if active.contains(where: { $0.waiting == "plan_limit" }) {
            return "Loading history paused — Claude plan limit"
        }
        let running = active.filter { $0.status == "running" }
        guard !running.isEmpty else { return "Loading history paused — reconnect the account" }
        if running.allSatisfy({ $0.waiting == "held" }) {
            return "Loading history waits — offline or a service is down, retrying"
        }
        let total = running.reduce(0) { $0 + Int((($1.upperTS - $1.floorTS) / day).rounded()) }
        let loaded = running.reduce(0) { $0 + Int((($1.upperTS - $1.reachedTS) / day).rounded()) }
        return "Loading history: \(loaded) of \(total) days"
    }
}
