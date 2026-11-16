import Foundation

/// Which client draws the Inbox. A platform difference is an input to the
/// screen models, never a fork in a view (mobile Inbox spec §2.3).
public enum Platform: Sendable {
    case mac, phone
}

/// What the owner let this phone do through the hub (ask #1349): Approve,
/// Retry, Dismiss of an approval, a target press and Make a Task need
/// `permissions`; a Reply needs `typing` (`inboxfeed.ActGrant`). The Mac
/// holds every grant.
public struct Grants: Sendable, Equatable {
    public var permissions: Bool
    public var typing: Bool

    public init(permissions: Bool, typing: Bool) {
        self.permissions = permissions
        self.typing = typing
    }

    public static let all = Self(permissions: true, typing: true)
}

/// The Inbox's times: the feed's stamps are RFC 3339 UTC, and every time
/// shown is computed here in the zone the client passes (its own
/// `TimeZone.current`), so the phone groups and labels by the phone's zone.
/// The formats are the Mac's (`InboxCardTexts`, `AutomationCardPresentation.relative`):
/// en_US_POSIX fixed patterns, so neither locale nor the 12/24-hour setting
/// changes them.
enum InboxTime {
    static func parse(_ stamp: String) -> Date? {
        if stamp.isEmpty { return nil }
        if let date = try? Date.ISO8601FormatStyle().parse(stamp) { return date }
        return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp)
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// "09:14", "14:00".
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "HH:mm", timeZone)
    }

    /// A list row's time (`InboxCardTexts.stamped`): "09:14" on `now`'s day
    /// in `timeZone`, else its day alone, "Oct 18".
    static func stamped(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        format(date, calendar(timeZone).isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d", timeZone)
    }

    /// "09:14" on `now`'s day, else "Oct 18, 09:14" (the reading pane's day and time).
    static func dayAndClock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        format(date, calendar(timeZone).isDate(date, inSameDayAs: now) ? "HH:mm" : "MMM d, HH:mm", timeZone)
    }

    /// "just now", "6 min ago", "2 h ago" (hours rounded, up to 48 h), "3 d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        return seconds < 60 ? TowerText.justNow : TowerText.ago(relative(seconds))
    }

    /// `AutomationCardPresentation.relative`: "45 s", "6 min", "2 h", "3 d".
    static func relative(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 { return TowerText.secondsSpan(s) }
        if s < 3600 { return TowerText.minutesSpan(s / 60) }
        if s < 48 * 3600 { return TowerText.hoursSpan(Int((Double(s) / 3600).rounded())) }
        return TowerText.daysSpan(Int((Double(s) / 86400).rounded()))
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar(timeZone)
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
