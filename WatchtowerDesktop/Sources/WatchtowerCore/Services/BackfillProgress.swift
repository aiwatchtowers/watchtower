import Foundation

/// The status bar's and tray's history backfill line.
package enum BackfillProgress {
    private static let day: Double = 86_400

    /// nil when nothing is loading (no rows, or every row done/off). The plan
    /// limit copy wins; otherwise only running rows count, and rows that are
    /// all paused (a revoked account) ask for a reconnect (R22). Rows held by
    /// a transient failure (offline, a service down) are counted as waiting;
    /// when every running row is held the line says it waits and retries (#580).
    package static func line(_ rows: [BackfillRow]) -> String? {
        let active = rows.filter { $0.status == "running" || $0.status == "paused" }
        guard !active.isEmpty else { return nil }
        if active.contains(where: { $0.waiting == "plan_limit" }) {
            return "Loading history paused — Claude plan limit"
        }
        let running = active.filter { $0.status == "running" }
        guard !running.isEmpty else { return "Loading history paused — reconnect the account" }
        let held = running.filter { $0.waiting == "held" }.count
        if held == running.count {
            return "Loading history waits — offline or a service is down, retrying"
        }
        let total = running.reduce(0) { $0 + Int((($1.upperTS - $1.floorTS) / day).rounded()) }
        let loaded = running.reduce(0) { $0 + Int((($1.upperTS - $1.reachedTS) / day).rounded()) }
        let line = "Loading history: \(loaded) of \(total) days"
        guard held > 0 else { return line }
        return line + (held == 1 ? ", 1 source waiting" : ", \(held) sources waiting")
    }
}
