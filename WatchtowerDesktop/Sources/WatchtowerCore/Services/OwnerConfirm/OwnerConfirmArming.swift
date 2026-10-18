import Foundation

/// The confirmation window's arming delay (AGENT-07, board #568): Confirm
/// stays disabled for `delay` after the window appears, so a click or a key
/// press already on its way when the window pops up cannot confirm it.
package enum OwnerConfirmArming {
    package static let delay: TimeInterval = 1

    package static func isArmed(shownAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(shownAt) >= delay
    }
}
