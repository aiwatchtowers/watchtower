import Foundation
import WatchtowerKit

/// Now's next meeting (mockup 1): the next non-all-day event that has not
/// ended, as a calendar row, with Record.
struct NextMeetingCardModel: Equatable {
    let id: String
    let row: CalendarRowModel
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
        id = event.id
        row = CalendarRowModel(
            start: event.startDate, end: event.endDate, title: event.title, location: event.location,
            attendees: event.attendees.count, isNext: true, now: now, calendar: calendar
        )
        meetingEvent = MeetingEvent(id: event.id, title: event.title, start: event.startDate, end: event.endDate)
    }

    var toneUses: [ToneUse] {
        [ToneUse(element: "next meeting record", tone: .red, role: .recording)] + row.toneUses
    }
}
