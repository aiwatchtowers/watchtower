import Foundation
import WatchtowerKit

/// Calendar strings on the phone's clock (or an injected calendar's, in
/// tests). All-day events are placed with `CalendarEvent.localStart(in:)`.
struct CalendarFormat {
    let calendar: Calendar
    private let clock: DateFormatter
    private let dayLabel: DateFormatter
    private let spokenDayLabel: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        clock = Self.formatter("HH:mm", calendar)
        dayLabel = Self.formatter("EEE, MMM d", calendar)
        spokenDayLabel = Self.formatter("EEEE, MMMM d", calendar)
    }

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    func time(_ date: Date) -> String { clock.string(from: date) }

    /// "Wed, Oct 7".
    func day(_ date: Date) -> String { dayLabel.string(from: date) }

    /// "Wednesday, October 7", for VoiceOver.
    func spokenDay(_ date: Date) -> String { spokenDayLabel.string(from: date) }

    /// "14:00–14:45", or "All day".
    func timeRange(_ event: CalendarEvent) -> String {
        event.isAllDay ? "All day" : "\(time(event.startDate))–\(time(event.endDate))"
    }

    /// Where the meeting happens: the conference provider, else the
    /// location; nil when neither is known.
    static func venue(_ event: CalendarEvent) -> String? {
        if let host = event.conferenceLink?.host?.lowercased() {
            if host == "meet.google.com" { return "Google Meet" }
            if host == "zoom.us" || host.hasSuffix(".zoom.us") { return "Zoom" }
            if host.hasPrefix("teams.") { return "Microsoft Teams" }
        }
        let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return location.isEmpty ? nil : location
    }

    /// "5 people" (the hub's dropped attendees included); nil for none.
    static func people(_ event: CalendarEvent) -> String? {
        let total = event.attendees.count + (event.attendeesMore ?? 0)
        switch total {
        case 0: return nil
        case 1: return "1 person"
        default: return "\(total) people"
        }
    }
}
