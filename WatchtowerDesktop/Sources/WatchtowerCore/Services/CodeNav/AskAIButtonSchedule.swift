import Foundation

/// When the ✦ button shows next to the editor's selection (spec 2026-10-02
/// §9.2), pure and clock-driven: it appears `settleDelay` after a non-empty
/// selection settles. Every selection change (typing moves it too) and
/// every scroll hides it and starts the wait again; a cleared selection
/// hides it for good; the popover suppresses it while open.
package struct AskAIButtonSchedule: Equatable, Sendable {
    package static let settleDelay: TimeInterval = 0.5

    package private(set) var hasSelection = false
    package private(set) var isVisible = false
    package private(set) var isSuppressed = false
    private var lastChange: Date?

    package init() {}

    /// When the button is due, if it is waiting for one.
    package var deadline: Date? {
        guard hasSelection, !isVisible, !isSuppressed, let lastChange else { return nil }
        return lastChange.addingTimeInterval(Self.settleDelay)
    }

    /// The page's `selection` message (also every keystroke's).
    package mutating func selectionChanged(hasSelection: Bool, at now: Date) {
        self.hasSelection = hasSelection
        unsettle(at: now)
    }

    /// The page's `scroll` message: the button's anchor moved.
    package mutating func scrolled(at now: Date) {
        unsettle(at: now)
    }

    /// The popover opened in its place.
    package mutating func suppress() {
        isSuppressed = true
        isVisible = false
    }

    /// The popover closed: a selection still there gets its button back
    /// after the usual pause.
    package mutating func resume(at now: Date) {
        isSuppressed = false
        unsettle(at: now)
    }

    /// The timer fired: shows the button once its deadline has passed.
    package mutating func tick(at now: Date) {
        if let deadline, now >= deadline { isVisible = true }
    }

    private mutating func unsettle(at now: Date) {
        isVisible = false
        lastChange = now
    }
}
