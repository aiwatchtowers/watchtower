import Foundation
import WatchtowerSync

/// Whether a hub's session is the one on screen (multi-hub spec §5.3).
enum SessionRole: Equatable, Sendable {
    case active
    case inactive
}

/// How often a session fetches by itself (multi-hub spec §5.3, board
/// #724). Whether the app is active at all is `HubSession.isActive`'s
/// job: every session's poll pauses while it is not.
enum SessionCadence {
    /// The safety poll of the session on screen (owner decision Q1, board
    /// #724): pushes bring changes, the poll is the net under them.
    static let safetyPollInterval: Duration = .seconds(60)
    /// The poll of a session not on screen with nothing on its way.
    static let inactivePollInterval: Duration = .seconds(300)

    /// The safety poll's wait before its next cycle: an inactive session
    /// with unsent work polls like the active one, so its echoes come back.
    static func pollInterval(role: SessionRole, hasPendingWork: Bool) -> Duration {
        switch role {
        case .active: safetyPollInterval
        case .inactive: hasPendingWork ? safetyPollInterval : inactivePollInterval
        }
    }

    /// The return to the foreground fetches at once unless the last
    /// successful fetch is younger than this: a Control Center peek for
    /// the session on screen, five minutes for the others.
    static func foregroundRefetchAfter(role: SessionRole) -> TimeInterval {
        switch role {
        case .active: 5
        case .inactive: 300
        }
    }
}
