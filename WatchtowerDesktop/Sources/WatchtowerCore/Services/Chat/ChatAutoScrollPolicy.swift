import CoreGraphics

/// Pure "is the thread at the bottom" decision (the `NowLine.visibility` /
/// `ChatSessionPolicy` precedent): no view/geometry types, so it is testable
/// without SwiftUI. `ChatThreadView` measures how far the bottom sentinel
/// sits below the visible viewport and feeds that distance here; the result
/// decides whether a streaming delta or a new message pulls the viewport
/// down (follow) or leaves it alone because the user scrolled up.
package enum ChatAutoScrollPolicy {
    /// Within this many points of the true bottom still counts as "at the
    /// bottom" — a user who scrolled up even slightly must not be yanked
    /// back down by the next delta.
    package static let bottomThreshold: CGFloat = 40

    /// `distanceFromBottom` is how far the sentinel's top edge sits below the
    /// viewport's visible bottom edge; 0 or negative means the sentinel is on
    /// screen (or the view has overscrolled past it), i.e. already at the
    /// bottom.
    package static func isAtBottom(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= bottomThreshold
    }
}
