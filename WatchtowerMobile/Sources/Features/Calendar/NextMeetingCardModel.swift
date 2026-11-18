import Foundation
import WatchtowerKit

/// Now's next meeting (mockup 1): the next non-all-day event that has not
/// ended, as a calendar row, with Record only around its start (#1785).
struct NextMeetingCardModel: Equatable {
    /// Record shows from this long before the start until this long after it;
    /// outside it the event's own screen (a tap on the row) still records.
    static let recordWindow: TimeInterval = 10 * 60

    let id: String
    let row: CalendarRowModel
    let meetingEvent: MeetingEvent
    /// Within `recordWindow` of the start.
    let showsRecord: Bool

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
        showsRecord = abs(event.startDate.timeIntervalSince(now)) <= Self.recordWindow
    }

    var toneUses: [ToneUse] {
        (showsRecord ? [ToneUse(element: "next meeting record", tone: .red, role: .recording)] : []) + row.toneUses
    }
}
