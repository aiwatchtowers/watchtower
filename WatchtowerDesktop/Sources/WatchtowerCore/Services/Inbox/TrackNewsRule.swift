import Foundation

/// The "with news" rule of Track my threads — the Swift twin of Go
/// `internal/tracks/news.go`; both read `internal/tracks/testdata/track_news.json`.
package enum TrackNewsRule {
    /// How long a never-read track counts as news after its last event (inclusive).
    package static let newsWindow: TimeInterval = 72 * 3600
    /// Days without an event after which a track with no news is quiet (inclusive).
    package static let quietDays = 30

    private static let unknown = Date(timeIntervalSince1970: 0)

    /// The later of `updatedAt` and `newestEventAt` (RFC 3339, fractional
    /// seconds optional); a side that does not parse is ignored, and the epoch
    /// means neither parsed.
    package static func lastEventAt(updatedAt: String, newestEventAt: String?) -> Date {
        [AutomationDates.parse(updatedAt), AutomationDates.parse(newestEventAt)]
            .compactMap { $0 }.max() ?? unknown
    }

    /// `has_updates`, or never read (`read_at` nil or "") with the last event
    /// within `newsWindow` of now (inclusive; a future event counts). An
    /// unknown last event is never news by time.
    package static func hasNews(track: InboxTrackCard, now: Date) -> Bool {
        if track.track.hasUpdates { return true }
        guard track.track.readAt?.isEmpty ?? true else { return false }
        let last = track.lastEventAt
        return last > unknown && last >= now.addingTimeInterval(-newsWindow)
    }

    /// No news and the last event at or before now − `days` × 24 h. An
    /// unknown last event is never quiet.
    package static func isQuiet(track: InboxTrackCard, now: Date, days: Int = quietDays) -> Bool {
        if hasNews(track: track, now: now) { return false }
        let last = track.lastEventAt
        return last > unknown && last <= now.addingTimeInterval(-TimeInterval(days) * 24 * 3600)
    }
}
