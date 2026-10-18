import Foundation

/// How much of a long session chat is built: the newest `count` entries,
/// grown by `step` when the owner asks for earlier ones. While the owner is
/// scrolled up the window is pinned to an absolute start index, so entries
/// appended at the end never move what is on screen.
package struct SessionFeedWindow: Equatable, Sendable {
    package static let step = 120

    private let step: Int
    private var count: Int
    /// Absolute index of the first shown entry while not following.
    private var pinnedStart: Int?

    /// True while the owner is at the bottom.
    package var following = true

    package init(step: Int = Self.step) {
        self.step = step
        self.count = step
    }

    package func range(total: Int) -> Range<Int> {
        if !following, let pinnedStart {
            return min(pinnedStart, total)..<total
        }
        return max(0, total - count)..<total
    }

    package func hasEarlier(total: Int) -> Bool {
        range(total: total).lowerBound > 0
    }

    /// Call when the feed or `following` changes: pins the start while the
    /// owner is scrolled up, releases it at the bottom.
    package mutating func sync(total: Int) {
        if following {
            pinnedStart = nil
        } else if pinnedStart == nil {
            pinnedStart = max(0, total - count)
        }
    }

    /// Grows by `step`; returns the id to keep anchored (the first entry shown
    /// before growing), nil when nothing is shown.
    package mutating func grow(entries: [SessionFeedEntry]) -> String? {
        let start = range(total: entries.count).lowerBound
        let anchor = start < entries.count ? entries[start].id : nil
        count += step
        if pinnedStart != nil {
            pinnedStart = max(0, start - step)
        }
        return anchor
    }
}
