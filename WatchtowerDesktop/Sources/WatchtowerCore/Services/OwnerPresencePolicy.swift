import Foundation

/// Which terminal session the owner is in (spec 2026-10-10-owner-asks-v2
/// Part 2.1): the app is active, its key window shows the workbench page
/// with that session's pane selected, and the screen is neither locked nor
/// asleep. Keyboard and mouse idleness are not inputs — the 10-minute rule
/// of the escalation covers an idle owner. At most one session is present,
/// and none of the inputs needs a permission.
///
/// Pure: `OwnerPresenceCenter` gathers the inputs, debounces a loss and
/// writes the result through `OwnerPresenceQueries.upsert`.
package enum OwnerPresencePolicy {
    /// What the key window shows.
    package enum KeyWindow: Equatable, Sendable {
        /// A workbench page with its selected session's pane on screen.
        case workbenchSession
        /// The same page with the ask drawer expanded beside or over the
        /// session's terminal: the owner is reading that session's ask.
        case workbenchSessionWithAskDrawer
        /// Anything else: another page, Settings, a sheet's own window, no
        /// key window.
        case other
    }

    /// The present session, or nil when the owner is in none.
    /// `selectedSession` is the session pane selected on the key window's
    /// workbench page — the one on screen, never a pane kept alive off
    /// screen.
    package static func presentSession(
        appActive: Bool,
        keyWindowShows: KeyWindow,
        selectedSession: Int64?,
        screenLocked: Bool,
        displaysAsleep: Bool
    ) -> Int64? {
        guard appActive, !screenLocked, !displaysAsleep else { return nil }
        switch keyWindowShows {
        case .workbenchSession, .workbenchSessionWithAskDrawer: return selectedSession
        case .other: return nil
        }
    }
}
