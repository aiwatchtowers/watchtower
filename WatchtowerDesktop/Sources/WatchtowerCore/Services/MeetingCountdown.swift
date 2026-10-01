import Foundation

/// The sidebar next-meeting card's "when": a live countdown while the meeting
/// is near, the start time once it is hours away — a raw minute count
/// ("in 1065 min") neither reads nor fits. Pure.
package enum MeetingCountdown {
    /// Up to this far ahead the card counts down in hours and minutes.
    package static let countdownHorizon: TimeInterval = 6 * 3600

    package static func text(start: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let remaining = Int(start.timeIntervalSince(now).rounded())
        guard remaining > 0 else { return "starting now" }
        if remaining < 60 {
            return remaining == 1 ? "in 1 sec" : "in \(remaining) sec"
        }
        let minutes = remaining / 60
        if minutes < 60 {
            return minutes == 1 ? "in 1 min" : "in \(minutes) min"
        }
        if TimeInterval(remaining) < countdownHorizon {
            let rest = minutes % 60
            return rest == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(rest) min"
        }
        let time = format(start, template: "jmm", calendar: calendar, locale: locale)
        if calendar.isDate(start, inSameDayAs: now) { return "today \(time)" }
        let today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: start)).day ?? 0
        if days == 1 { return "tomorrow \(time)" }
        if days < 7 { return "\(format(start, template: "EEE", calendar: calendar, locale: locale)) \(time)" }
        return "\(format(start, template: "MMMd", calendar: calendar, locale: locale)) \(time)"
    }

    private static func format(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
