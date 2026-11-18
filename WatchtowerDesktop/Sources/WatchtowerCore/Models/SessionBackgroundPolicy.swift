import Foundation

/// Whether a session's background agents still count as running.
package enum SessionBackgroundVerdict: Equatable, Sendable {
    case running
    case over
}

/// The one staleness seam of the background agent count
/// (`terminal_sessions.agent_background`, spec 2026-10-10-session-background-agents
/// §5.1, §10) and of the background shell count beside it
/// (`agent_background_shells`, board #1712): nothing else compares
/// `agent_background_at` with a duration.
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
    /// How long after their last report background shells still count as
    /// running (Go's `sessionstate.BackgroundShellCap`, board #1712): a
    /// shell that never exits (a dev server) must not read as working
    /// forever, and nothing tells it from a long CI watch.
    package static let shellCap: TimeInterval = 2 * 60 * 60

    package static let current = Self()

    package func verdict(count: Int, lastReport: Date, now: Date) -> SessionBackgroundVerdict {
        if lastReport > now { return .over }
        if count > 0 { return .running }
        return now.timeIntervalSince(lastReport) < Self.grace ? .running : .over
    }

    /// Whether `shells` background shells reported at `lastReport` still
    /// run at `now`: unlike the agent count they end on the clock, at
    /// `shellCap`, since Claude Code's registry reads the same for a CI
    /// watch and a dev server; a report from the future is over.
    package func shellsRun(shells: Int, lastReport: Date, now: Date) -> Bool {
        shells > 0 && lastReport <= now && now.timeIntervalSince(lastReport) < Self.shellCap
    }

    /// Whether a count of agents and shells reported at `lastReport` is
    /// silent long enough at `now` for the probe. It never ends the count by
    /// itself.
    package func needsProbe(count: Int, shells: Int = 0, lastReport: Date, now: Date) -> Bool {
        (count > 0 || shells > 0) && lastReport <= now && now.timeIntervalSince(lastReport) >= Self.staleAfter
    }
}
