import Foundation

/// The Inbox "from today" rule: an item is from today when the later of its
/// creation and its last mention falls at or after the first instant of
/// today's local date in `calendar`'s zone. Go twin: `db.IsFromToday`, over
/// the shared fixture `internal/inbox/testdata/from_today.json`.
package enum InboxToday {
    /// Local midnight of `now`'s date, or the first instant after a DST gap
    /// that swallows midnight.
    package static func startOfToday(now: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: now)
    }

    package static func isFromToday(
        createdAt: Date,
        mentionedAt: Date?,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        max(createdAt, mentionedAt ?? createdAt) >= startOfToday(now: now, calendar: calendar)
    }

    /// `startOfToday` in the UTC form `inbox_items` stores, for SQL
    /// `MAX(created_at, mentioned_at) >= ?`.
    package static func sinceUTC(now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: startOfToday(now: now, calendar: calendar))
    }
}
