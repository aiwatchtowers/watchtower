import CoreGraphics

/// Pure "follow the conversation" decisions (the `NowLine.visibility` /
/// `ChatSessionPolicy` precedent): no view/geometry types, so they are
/// testable without SwiftUI. `ChatThreadView` feeds consecutive measurements
/// of the thread content into a `ChatFollowTracker`, which decides whether
/// the view keeps pinning itself to the latest content (a streaming delta, a
/// tool step, an artifact block, a new row) or leaves it alone because the
/// user scrolled up.
package enum ChatAutoScrollPolicy {
    /// Scrolling back down to within this many points of the true bottom
    /// re-pins the view.
    package static let bottomThreshold: CGFloat = 40

    /// A content-top move no larger than this is not (yet) a scroll; moves
    /// that small still add up against the tracker's baseline.
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

    /// Whether a new live turn just started — a send, regenerate, edit or
    /// continue. Starting a turn always re-pins the view, whatever an earlier
    /// scroll left behind.
    package static func turnStarted(previousLiveMessageID: Int64?, currentLiveMessageID: Int64?) -> Bool {
        guard let current = currentLiveMessageID else { return false }
        return current != previousLiveMessageID
    }

    /// What the thread view watches for scroll purposes, in one value, so a
    /// conversation switch, a search-hit jump and a turn start landing in the
    /// same update are told apart regardless of handler order.
    package struct ThreadState: Equatable, Sendable {
        package let conversationID: Int64?
        package let lastMessageID: Int64?
        package let scrollTarget: Int64?
        /// The open conversation's live reply, if any. `liveTurn` is
        /// per-conversation, so a switch into a streaming conversation
        /// changes it too — that alone is not a turn start.
        package let liveMessageID: Int64?

        package init(
            conversationID: Int64?,
            lastMessageID: Int64?,
            scrollTarget: Int64?,
            liveMessageID: Int64? = nil
        ) {
            self.conversationID = conversationID
            self.lastMessageID = lastMessageID
            self.scrollTarget = scrollTarget
            self.liveMessageID = liveMessageID
        }
    }

    package enum ThreadChange: Equatable, Sendable {
        /// A deliberate jump (a ⌘K search hit): land on that message, not
        /// following — even when the same update switched the conversation.
        case jumpToMessage(Int64)
        /// A plain conversation switch: land at the bottom, following.
        case switchedConversation
        /// A new live turn in the same conversation (send, regenerate, edit,
        /// continue): re-pin to the bottom, whatever an earlier scroll left.
        case turnStarted
        /// A new last row in the same conversation.
        case newLastRow
        case none
    }

    /// The thread view's first state (it mounted): a pending target — a ⌘K
    /// hit opened from a project page, which mounts the view in the same
    /// update — is a jump; anything else lands via the tracker's first
    /// measurement.
    package static func mountChange(_ state: ThreadState) -> ThreadChange {
        state.scrollTarget.map { .jumpToMessage($0) } ?? .none
    }

    package static func threadChange(from old: ThreadState, to new: ThreadState) -> ThreadChange {
        if new.scrollTarget != old.scrollTarget, let target = new.scrollTarget { return .jumpToMessage(target) }
        if new.conversationID != old.conversationID { return .switchedConversation }
        if turnStarted(previousLiveMessageID: old.liveMessageID, currentLiveMessageID: new.liveMessageID) {
            return .turnStarted
        }
        if new.lastMessageID != old.lastMessageID { return .newLastRow }
        return .none
    }
}

/// The follow state across consecutive measurements.
///
/// A scroll away is read from the content's top edge moving down against a
/// baseline that only advances on a real move, so a slow drag made of
/// sub-epsilon steps adds up to a scroll instead of being dropped as jitter
/// one sample at a time. Content growing under the viewport only moves the
/// content's bottom edge, so it never reads as a scroll (a single
/// bottom-distance threshold could not tell the two apart: one streamed
/// paragraph taller than the threshold flipped following off). A following
/// view is pulled to the bottom only when the content grew or the viewport
/// shrank, never merely because it sits a little above the bottom.
package struct ChatFollowTracker: Equatable, Sendable {
    package typealias Metrics = ChatAutoScrollPolicy.Metrics

    package private(set) var following: Bool
    /// The last measurement seen; nil right after a reset.
    package private(set) var lastMetrics: Metrics?
    /// `contentTop` at the last real move (or reset); small moves are
    /// measured against it, not against the previous sample.
    private var baselineTop: CGFloat?

    package init(following: Bool = true) {
        self.following = following
    }

    /// A conversation switch (`following: true`: land at the bottom) or a
    /// jump to a specific message (`following: false`: stay on it). The next
    /// measurement starts a fresh baseline.
    package mutating func reset(following: Bool) {
        self.following = following
        lastMetrics = nil
        baselineTop = nil
    }

    /// A send or "Jump to latest": follow again from wherever the view is.
    package mutating func repin() {
        following = true
    }

    /// Feeds one measurement; returns whether the view should scroll to the
    /// bottom now.
    package mutating func observe(_ current: Metrics) -> Bool {
        let eps = ChatAutoScrollPolicy.scrollEpsilon
        let distance = current.distanceFromBottom
        defer { lastMetrics = current }
        guard let baseline = baselineTop, let previous = lastMetrics else {
            // First measurement after a reset: land at the bottom if following.
            baselineTop = current.contentTop
            if distance <= eps { following = true }
            return following && distance > eps
        }
        let topMove = current.contentTop - baseline
        if topMove > eps && distance > eps {
            // Scrolled up with the bottom below the viewport: a scroll away,
            // however small. An upward move ending in overscroll (the rubber
            // band at the bottom springing back) takes the next branch.
            following = false
            baselineTop = current.contentTop
        } else if distance <= eps {
            following = true
            baselineTop = current.contentTop
        } else if topMove < -eps {
            if ChatAutoScrollPolicy.isAtBottom(distanceFromBottom: distance) { following = true }
            baselineTop = current.contentTop
        }
        // Otherwise a small move: the baseline stays, so slow moves add up.
        let grew = current.contentHeight > previous.contentHeight + eps
            || current.viewportHeight < previous.viewportHeight - eps
        return following && grew && distance > eps
    }
}
