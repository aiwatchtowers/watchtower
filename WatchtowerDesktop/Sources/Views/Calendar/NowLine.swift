import CoreGraphics
import Foundation

/// Placement of the red "now" marker among a day's timed rows, kept as a
/// pure helper (the `TranscriptFormatting` pattern) so it stays unit-testable.
enum NowLine {
    /// Scroll-anchor id of the marker row (`.id` on the row, `scrollTo` target).
    static let nowLineID = "now-line"

    /// A row of the Today section's timed list: a meetings-list entry
    /// (event or standalone recording), or the now marker.
    enum TodayRow: Identifiable {
        case entry(MeetingListEntry)
        case nowLine

        var id: AnyHashable {
            switch self {
            case .entry(let entry): return AnyHashable(entry.id)
            case .nowLine: return AnyHashable(NowLine.nowLineID)
            }
        }
    }

    /// Where the now marker sits relative to the scroll viewport, derived
    /// from the marker row's published frame.
    enum Visibility: Equatable {
        case visible, above, below

        /// SF Symbol for the jump-to-now button; nil while the marker is on
        /// screen (no button rendered).
        var jumpArrowSymbol: String? {
            switch self {
            case .above: return "arrow.up"
            case .below: return "arrow.down"
            case .visible: return nil
            }
        }
    }

    /// Index in `starts` (the day's timed-row start dates, sorted ascending)
    /// where the marker row is inserted: before the first start with
    /// `start > now`. The boundary is strictly `>` so a row starting exactly
    /// at `now` counts as started (ongoing meetings stay above the line); if
    /// every row has started, returns `starts.count`.
    /// Note: an unparseable event `start_time` (or recording timestamp) falls
    /// back to `Date.distantPast` upstream, so a malformed row compares as
    /// already started and never itself becomes the insertion point — its
    /// on-screen position still follows the section's own ordering.
    static func nowLineIndex(starts: [Date], now: Date) -> Int {
        starts.firstIndex { $0 > now } ?? starts.count
    }

    /// `entries` mapped to `.entry` rows with `.nowLine` inserted at
    /// `nowLineIndex` over their `sortDate`s — the single insertion site the
    /// view renders from.
    static func rows(entries: [MeetingListEntry], now: Date) -> [TodayRow] {
        var rows = entries.map(TodayRow.entry)
        rows.insert(.nowLine, at: nowLineIndex(starts: entries.map(\.sortDate), now: now))
        return rows
    }

    /// Marker position relative to the viewport, or nil while there is
    /// nothing to compare (no marker frame published, or a degenerate
    /// viewport).
    static func visibility(frame: CGRect?, viewportHeight: CGFloat) -> Visibility? {
        guard let frame, viewportHeight > 0 else { return nil }
        if frame.maxY <= 0 { return .above }
        if frame.minY >= viewportHeight { return .below }
        return .visible
    }
}
