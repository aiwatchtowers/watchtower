import Foundation

/// Whether a session's background agents still count as running.
package enum SessionBackgroundVerdict: Equatable, Sendable {
    case running
    case over
}

/// The one staleness seam of the background agent count
/// (`terminal_sessions.agent_background`, spec 2026-10-10-session-background-agents
/// §5.1, §10): nothing else compares `agent_background_at` with a duration.
///
/// A count above zero never ends on the Desktop's clock — Go ends it (the
/// count's next report or the staleness probe of §10). A count lowered to
/// zero runs for `grace` only: the main agent is about to wake. A report
/// stamped in the future is over. The probe's "silent for 30 min" check
/// joins this type, not its callers.
package struct SessionBackgroundPolicy: Sendable {
    /// How long a count of zero still shows as background.
    package static let grace: TimeInterval = 120

    package static let current = Self()

    package func verdict(count: Int, lastReport: Date, now: Date) -> SessionBackgroundVerdict {
        if lastReport > now { return .over }
        if count > 0 { return .running }
        return now.timeIntervalSince(lastReport) < Self.grace ? .running : .over
    }
}
