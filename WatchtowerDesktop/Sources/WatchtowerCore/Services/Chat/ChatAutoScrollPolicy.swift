import CoreGraphics

/// Pure "follow the conversation" decision (the `NowLine.visibility` /
/// `ChatSessionPolicy` precedent): no view/geometry types, so it is testable
/// without SwiftUI. `ChatThreadView` measures where the thread content sits in
/// the viewport and feeds consecutive measurements here; the result decides
/// whether the view keeps pinning itself to the latest content (a streaming
/// delta, a tool step, an artifact block, a new row) or leaves it alone
/// because the user scrolled up.
package enum ChatAutoScrollPolicy {
    /// Scrolling back down to within this many points of the true bottom
    /// re-pins the view.
    package static let bottomThreshold: CGFloat = 40

    /// A content-top move no larger than this is layout jitter, not a scroll.
    package static let scrollEpsilon: CGFloat = 1

    /// `distanceFromBottom` is how far the content's bottom edge sits below
    /// the viewport's visible bottom edge; 0 or negative means the bottom is
    /// on screen (or the view has overscrolled past it).
    package static func isAtBottom(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= bottomThreshold
    }

    /// One measurement of the thread content in the viewport's coordinates.
    package struct Metrics: Equatable, Sendable {
        /// The content's top edge: it moves down when the viewport scrolls
        /// up, and stays put when content grows below it.
        package let contentTop: CGFloat
        package let contentHeight: CGFloat
        package let viewportHeight: CGFloat

        package init(contentTop: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
            self.contentTop = contentTop
            self.contentHeight = contentHeight
            self.viewportHeight = viewportHeight
        }

        package var distanceFromBottom: CGFloat { contentTop + contentHeight - viewportHeight }
    }

    package struct Decision: Equatable, Sendable {
        /// Whether the view keeps tracking the latest content.
        package let following: Bool
        /// Whether the view should scroll to the bottom now: the content grew
        /// (or the viewport shrank) under a following view.
        package let pullToBottom: Bool

        package init(following: Bool, pullToBottom: Bool) {
            self.following = following
            self.pullToBottom = pullToBottom
        }
    }

    /// Content growing under the viewport only moves the content's bottom
    /// edge, so it never reads as "the user left the bottom" — a single
    /// bottom-distance threshold could not tell the two apart, and one
    /// streamed paragraph taller than the threshold flipped following off
    /// with the user never touching the scroll view. Only the content's top
    /// edge moving down (the viewport scrolled up) while the bottom is below
    /// the viewport stops following — however small the scroll, so the next
    /// delta never yanks a reader back. An upward move ending in overscroll
    /// (the rubber band at the bottom springing back) is not a scroll away.
    /// Following resumes at the exact bottom, or on a scroll down to within
    /// `bottomThreshold` of it.
    package static func decide(wasFollowing: Bool, previous: Metrics?, current: Metrics) -> Decision {
        let distance = current.distanceFromBottom
        let topMove = previous.map { current.contentTop - $0.contentTop } ?? 0
        let following: Bool
        if topMove > scrollEpsilon && distance > scrollEpsilon {
            following = false
        } else if distance <= scrollEpsilon {
            following = true
        } else if topMove < -scrollEpsilon && isAtBottom(distanceFromBottom: distance) {
            following = true
        } else {
            following = wasFollowing
        }
        return Decision(following: following, pullToBottom: following && distance > scrollEpsilon)
    }

    /// Whether a new live turn just started — a send, regenerate, edit or
    /// continue. Starting a turn always re-pins the view, whatever an earlier
    /// scroll left behind.
    package static func turnStarted(previousLiveMessageID: Int64?, currentLiveMessageID: Int64?) -> Bool {
        guard let current = currentLiveMessageID else { return false }
        return current != previousLiveMessageID
    }
}
