import Foundation

/// Placement of the red "now" marker among a day's timed events, kept as a
/// pure helper (the `TranscriptFormatting` pattern) so it stays unit-testable.
enum NowLine {
    /// Index in `events` (the day's timed events, sorted by start) where the
    /// marker row is inserted: before the first event with `startDate > now`.
    /// The boundary is strictly `>` so an event starting exactly at `now`
    /// counts as started (ongoing meetings stay above the line); if every
    /// event has started, returns `events.count`.
    static func nowLineIndex(events: [CalendarEvent], now: Date) -> Int {
        events.firstIndex { $0.startDate > now } ?? events.count
    }
}
