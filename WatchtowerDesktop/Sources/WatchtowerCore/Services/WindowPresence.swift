import Foundation

/// Where a window is for a view that holds a long-lived flow (the pairing
/// sheet, board #2188): on screen, still open but covered, or gone. Pure, so
/// the AppKit side only gathers the facts.
package enum WindowPresence: Equatable {
    case onScreen
    /// Open but not seen: another app in front, another Space, the display
    /// asleep, minimised, or the whole app hidden (Cmd-H).
    case occluded
    /// Closed or ordered out, or no window at all.
    case gone

    package static func of(
        occlusionVisible: Bool, isVisible: Bool, isMiniaturized: Bool, appHidden: Bool, windowExists: Bool
    ) -> Self {
        guard windowExists else { return .gone }
        if appHidden || isMiniaturized { return .occluded }
        if !isVisible { return .gone }
        return occlusionVisible ? .onScreen : .occluded
    }
}
