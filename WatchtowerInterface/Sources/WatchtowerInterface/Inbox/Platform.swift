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

    /// "9:14", "14:00": the 24-hour clock in `timeZone`.
    static func clock(_ date: Date, timeZone: TimeZone) -> String {
        let parts = calendar(timeZone).dateComponents([.hour, .minute], from: date)
        let minute = parts.minute ?? 0
        return "\(parts.hour ?? 0):\(minute < 10 ? "0" : "")\(minute)"
    }

    /// The clock alone on `now`'s day in `timeZone`, else "Nov 12, 9:14".
    static func clock(_ date: Date, now: Date, timeZone: TimeZone) -> String {
        let calendar = calendar(timeZone)
        if calendar.isDate(date, inSameDayAs: now) { return clock(date, timeZone: timeZone) }
        let parts = calendar.dateComponents([.month, .day], from: date)
        let month = months[((parts.month ?? 1) - 1 + 12) % 12]
        return "\(month) \(parts.day ?? 1), \(clock(date, timeZone: timeZone))"
    }

    /// "just now", "6 min ago", "2 h ago", "3 d ago".
    static func ago(_ date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return TowerText.justNow }
        if minutes < 60 { return TowerText.minutesAgo(minutes) }
        if minutes < 24 * 60 { return TowerText.hoursAgo(minutes / 60) }
        return TowerText.daysAgo(minutes / (24 * 60))
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
