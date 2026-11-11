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

    /// The first instant of the local day after `now`'s: when "today"
    /// moves with no database write. DST-safe: a day whose midnight a gap
    /// swallows starts at the first instant after it (`startOfToday`'s rule).
    package static func nextMidnight(after now: Date, calendar: Calendar) -> Date {
        let midnight = DateComponents(hour: 0, minute: 0, second: 0)
        guard let next = calendar.nextDate(after: now, matching: midnight, matchingPolicy: .nextTime) else {
            return now.addingTimeInterval(86_400)
        }
        return calendar.startOfDay(for: next)
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

/// Calls `onChange` after each notification that may move "today" with no
/// database write, which no table observation sees: the system's day
/// change, a time-zone change and (the app adds it: WatchtowerCore stays
/// AppKit-free) a wake from sleep. Its observers go with it.
package final class InboxDayChangeObserver {
    /// One notification to follow, on the center that posts it.
    package struct Signal {
        package let center: NotificationCenter
        package let name: Notification.Name

        package init(center: NotificationCenter, name: Notification.Name) {
            self.center = center
            self.name = name
        }
    }

    private let tokens: [(center: NotificationCenter, token: any NSObjectProtocol)]

    /// `onChange` runs on the main actor, after the posting returns.
    package init(signals: [Signal], onChange: @escaping @MainActor @Sendable () -> Void) {
        tokens = signals.map { signal in
            (signal.center, signal.center.addObserver(forName: signal.name, object: nil, queue: nil) { _ in
                Task { @MainActor in onChange() }
            })
        }
    }

    deinit {
        for entry in tokens { entry.center.removeObserver(entry.token) }
    }

    /// The day change and the time-zone change, both on `center`.
    package static func systemSignals(center: NotificationCenter = .default) -> [Signal] {
        [Signal(center: center, name: .NSCalendarDayChanged),
         Signal(center: center, name: .NSSystemTimeZoneDidChange)]
    }
}
