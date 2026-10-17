import Foundation

/// Whether the app's UI is on screen (board #731): at least one window the
/// owner can bring to front (`canBecomeMain` — the main window, Settings,
/// Logs; never the menu-bar extra's status window) is visible, not
/// minimised and not fully covered, and the app is not hidden. Pure, so the
/// AppKit side (`UIVisibilityCenter`) only gathers the window facts.
package enum UIVisibilityPolicy {
    package struct Window: Equatable {
        package var canBecomeMain: Bool
        package var isVisible: Bool
        package var isMiniaturized: Bool
        /// `occlusionState` lacks `.visible`: covered by other windows, on
        /// another Space, or the display is asleep.
        package var isOccluded: Bool

        package init(canBecomeMain: Bool, isVisible: Bool, isMiniaturized: Bool, isOccluded: Bool) {
            self.canBecomeMain = canBecomeMain
            self.isVisible = isVisible
            self.isMiniaturized = isMiniaturized
            self.isOccluded = isOccluded
        }
    }

    package static func isOnScreen(_ windows: [Window], appHidden: Bool) -> Bool {
        guard !appHidden else { return false }
        return windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized && !$0.isOccluded }
    }
}

/// The visibility gate of a periodic UI refresh (board #731): a tick off
/// screen is skipped and remembered, and coming back on screen after a
/// skipped tick asks for one refresh at once — so a poller in the tray costs
/// a wakeup and nothing else, and the window never shows data older than
/// one tick. Starts on screen: an unknown visibility (a test host, the
/// first moments of a launch) must not freeze a view.
package struct ForegroundRefreshGate: Equatable {
    package private(set) var isOnScreen: Bool
    private var missedWhileHidden = false

    package init(isOnScreen: Bool = true) {
        self.isOnScreen = isOnScreen
    }

    /// A periodic tick: true when the refresh runs now.
    package mutating func tick() -> Bool {
        guard isOnScreen else {
            missedWhileHidden = true
            return false
        }
        return true
    }

    /// The UI went on or off screen: true when a refresh runs now (back on
    /// screen after at least one skipped tick).
    package mutating func setOnScreen(_ onScreen: Bool) -> Bool {
        let wasOnScreen = isOnScreen
        isOnScreen = onScreen
        guard onScreen, !wasOnScreen, missedWhileHidden else { return false }
        missedWhileHidden = false
        return true
    }
}
