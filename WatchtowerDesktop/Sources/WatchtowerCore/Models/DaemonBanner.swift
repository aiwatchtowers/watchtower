import Foundation

/// The app-wide daemon banner over every tab: the one place with a Start
/// control while the daemon is down (tabs and Home cards only say so).
package enum DaemonBanner: Equatable, Sendable {
    /// Down past `FeatureReadiness.daemonDownGrace`: "Watchtower isn't
    /// running" with Start.
    case stopped
    /// A start failed or the daemon died right after one: the reason, with
    /// Retry and Open Logs.
    case failed(String)

    /// A failure wins: it says why, and its Retry is the same start.
    package static func current(failure: String?, daemonDown: Bool) -> Self? {
        if let failure { return .failed(failure) }
        return daemonDown ? .stopped : nil
    }
}
