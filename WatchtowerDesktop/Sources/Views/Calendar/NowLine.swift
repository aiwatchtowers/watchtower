import CoreGraphics
import Foundation

/// Placement of the red "now" marker among a day's timed events, kept as a
/// pure helper (the `TranscriptFormatting` pattern) so it stays unit-testable.
enum NowLine {
    /// Scroll-anchor id of the marker row (`.id` on the row, `scrollTo` target).
    static let nowLineID = "now-line"

    /// A row of the Today section's timed list: an event, or the now marker.
    enum TodayRow: Identifiable {
        case event(CalendarEvent)
        case nowLine

        var id: String {
            switch self {
            case .event(let event): return event.id
            case .nowLine: return NowLine.nowLineID
            }
        }
    }

    /// Where the now marker sits relative to the scroll viewport, derived
    /// from the marker row's published frame.
    enum Visibility: Equatable {
        case visible, above, below
    }

    /// Index in `events` (the day's timed events, sorted by start) where the
    /// marker row is inserted: before the first event with `startDate > now`.
    /// The boundary is strictly `>` so an event starting exactly at `now`
    /// counts as started (ongoing meetings stay above the line); if every
    /// event has started, returns `events.count`.
    /// Note: `CalendarEvent.startDate` falls back to `Date.distantPast` on an
    /// unparseable `start_time`, so a malformed event counts as started and
    /// stays above the line.
    static func nowLineIndex(events: [CalendarEvent], now: Date) -> Int {
        events.firstIndex { $0.startDate > now } ?? events.count
    }

    /// `events` mapped to `.event` rows with `.nowLine` inserted at
    /// `nowLineIndex` — the single insertion site the view renders from.
    static func rows(events: [CalendarEvent], now: Date) -> [TodayRow] {
        var rows = events.map(TodayRow.event)
        rows.insert(.nowLine, at: nowLineIndex(events: events, now: now))
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
