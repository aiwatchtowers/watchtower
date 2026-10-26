import Foundation

/// Whether the owner is away from the Mac (spec 2026-10-25-mobile-workbench-remote
/// §5.1): the phone gets pushes only then. Unlike `OwnerPresencePolicy` this
/// does count idleness — the screen is locked, the displays are asleep, the
/// console has had no input for `idleThreshold`, or the console user session
/// is inactive (fast user switching). Pure: `OwnerAwayCenter` gathers the
/// inputs.
package enum OwnerAwayPolicy {
    /// Seconds without input after which the owner reads as away.
    package static let idleThreshold: TimeInterval = 180

    package static func isAway(
        screenLocked: Bool, displaysAsleep: Bool, idleSeconds: TimeInterval, sessionActive: Bool
    ) -> Bool {
        screenLocked || displaysAsleep || idleSeconds >= idleThreshold || !sessionActive
    }
}
