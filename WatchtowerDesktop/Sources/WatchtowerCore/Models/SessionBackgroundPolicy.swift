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
/// count's next report or the staleness probe of §10); two failed probes in
/// a row only show it over (`SessionAgentStatus.resolve`'s `displayOver`). A count lowered to
/// zero runs for `grace` only: the main agent is about to wake. A report
/// stamped in the future is over. When a count is silent long enough to
/// probe (`needsProbe`) is this type's call too.
package struct SessionBackgroundPolicy: Sendable {
    /// How long a count of zero still shows as background.
    package static let grace: TimeInterval = 120
    /// How long a count above zero may go without a report before the
    /// Desktop runs `workbench session-probe` (the Go side's
    /// `probeStaleAfter`).
    package static let staleAfter: TimeInterval = 30 * 60

    package static let current = Self()

    package func verdict(count: Int, lastReport: Date, now: Date) -> SessionBackgroundVerdict {
        if lastReport > now { return .over }
        if count > 0 { return .running }
        return now.timeIntervalSince(lastReport) < Self.grace ? .running : .over
    }

    /// Whether a count reported at `lastReport` is silent long enough at
    /// `now` for the probe. It never ends the count by itself.
    package func needsProbe(count: Int, lastReport: Date, now: Date) -> Bool {
        count > 0 && lastReport <= now && now.timeIntervalSince(lastReport) >= Self.staleAfter
    }
}
