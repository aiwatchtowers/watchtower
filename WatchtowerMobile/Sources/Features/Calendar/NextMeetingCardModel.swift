import Foundation
import WatchtowerKit

/// The Now tab's next-meeting card: the next non-all-day event that has
/// not ended, with Record.
struct NextMeetingCardModel: Equatable {
    let id: String
    /// "Next · in 25 min", or "Now · until 14:45" while it runs.
    let header: String
    let title: String
    /// "14:00–14:45 · 5 people · prep ready".
    let line: String
    let meetingEvent: MeetingEvent

    /// The current or next meeting: non-all-day, `end > now`, earliest
    /// start first.
    static func pick(_ events: [CalendarEvent], now: Date) -> CalendarEvent? {
        events
            .filter { !$0.isAllDay && $0.endDate > now }
            .min { lhs, rhs in lhs.startDate != rhs.startDate ? lhs.startDate < rhs.startDate : lhs.id < rhs.id }
    }

    init?(events: [CalendarEvent], now: Date, calendar: Calendar) {
        guard let event = Self.pick(events, now: now) else { return nil }
        let format = CalendarFormat(calendar: calendar)
        id = event.id
        title = event.title
        header = event.startDate <= now
            ? "Now · until \(format.time(event.endDate))"
            : "Next · \(Self.relative(from: now, to: event.startDate))"
        let range = calendar.isDate(event.startDate, inSameDayAs: now)
            ? format.timeRange(event)
            : "\(format.day(event.startDate)) · \(format.timeRange(event))"
        let prep = event.prepBullets.isEmpty ? "no prep yet" : "prep ready"
        line = ([range] + [CalendarFormat.people(event)].compactMap { $0 } + [prep]).joined(separator: " · ")
        meetingEvent = MeetingEvent(id: event.id, title: event.title, start: event.startDate, end: event.endDate)
    }

    /// "in 25 min", "in 2 h 5 min", "in 3 d".
    static func relative(from now: Date, to start: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        switch minutes {
        case ..<60: return "in \(max(minutes, 1)) min"
        case ..<1_440:
            let rest = minutes % 60
            return rest == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(rest) min"
        default: return "in \(minutes / 1_440) d"
        }
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "next meeting record", tone: .red, role: .recording)]
    }
}
