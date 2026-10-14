import Foundation
import WatchtowerKit
import WatchtowerSync

// MARK: - Agenda day

/// One event card on the agenda.
struct EventCardModel: Identifiable, Equatable {
    let id: String
    let title: String
    /// The left column: "14:00", or "All day".
    let timeText: String
    /// "14:00–14:45 · Google Meet".
    let detailLine: String
    let pills: [EventPill]
    let isPast: Bool
    /// The current or next meeting of today: accent card with Record and
    /// Prep.
    let isHighlighted: Bool
    /// What the Record button records; nil for an all-day event.
    let meetingEvent: MeetingEvent?

    var showsRecord: Bool { isHighlighted && meetingEvent != nil }
    var showsPrep: Bool { isHighlighted }

    /// The current or next meeting is the accent card; every other card is
    /// plain (design pass C3).
    var cardStyle: CardStyle { isHighlighted ? .highlighted : .plain }

    /// The buttons on the card, in order.
    var actionTitles: [String] {
        (showsRecord ? ["Record"] : []) + (showsPrep ? ["Prep"] : [])
    }

    var toneUses: [ToneUse] {
        pills.map { ToneUse(element: "event pill \($0.text)", tone: $0.tone, role: $0.role) }
            + (showsRecord ? [ToneUse(element: "record button", tone: .red, role: .recording)] : [])
            + (isHighlighted ? [ToneUse(element: "highlighted card", tone: .accent, role: .info)] : [])
    }
}

enum AgendaRow: Identifiable, Equatable {
    case event(EventCardModel)
    /// The red now line, with the time.
    case nowLine(String)

    var id: String {
        switch self {
        case let .event(card): "event-\(card.id)"
        case .nowLine: "now-line"
        }
    }
}

/// One agenda day: its events (all-day first, then by start), the now line
/// on today only, and the current or next meeting highlighted.
struct AgendaDayModel {
    let rows: [AgendaRow]
    let cards: [EventCardModel]
    /// "No events" for a day without any.
    let emptyText: String?
    /// The now line's time; nil on any day but today.
    let nowLineText: String?

    /// The highlighted card's row, scrolled to the middle on appear and on
    /// every day change (design pass spec §3 bug 2); nil when no card is
    /// highlighted, so the day stays at the top.
    var highlightedRowID: String? {
        rows.first { row in
            if case let .event(card) = row { card.isHighlighted } else { false }
        }?.id
    }

    init(
        day: Date,
        snapshot: CalendarReplicaSnapshot,
        recordings: PhoneRecordingsSnapshot,
        now: Date,
        calendar: Calendar
    ) {
        let format = CalendarFormat(calendar: calendar)
        let events = Self.events(on: day, in: snapshot.events, calendar: calendar)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let highlightedID = isToday ? NextMeetingCardModel.pick(events, now: now)?.id : nil

        cards = events.map { event in
            EventCardModel(
                id: event.id,
                title: event.title,
                timeText: event.isAllDay ? "All day" : format.time(event.startDate),
                detailLine: ([format.timeRange(event)] + [CalendarFormat.venue(event)].compactMap { $0 }).joined(separator: " · "),
                pills: EventRecordingStatus(event: event, snapshot: snapshot, recordings: recordings, now: now).pills,
                isPast: event.localEnd(in: calendar) <= now,
                isHighlighted: event.id == highlightedID,
                meetingEvent: event.isAllDay
                    ? nil
                    : MeetingEvent(id: event.id, title: event.title, start: event.startDate, end: event.endDate)
            )
        }
        emptyText = cards.isEmpty ? "No events" : nil
        nowLineText = isToday ? format.time(now) : nil

        var rows = cards.map(AgendaRow.event)
        if let nowLineText {
            // Before the first timed event that has not started yet.
            let index = events.firstIndex { !$0.isAllDay && $0.startDate > now } ?? cards.count
            rows.insert(.nowLine(nowLineText), at: index)
        }
        self.rows = rows
    }

    /// The events touching `day` on `calendar`'s clock: all-day first, then
    /// by start, then title.
    static func events(on day: Date, in events: [CalendarEvent], calendar: Calendar) -> [CalendarEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events
            .filter { event in
                let eventStart = event.localStart(in: calendar)
                let eventEnd = event.localEnd(in: calendar)
                return (eventStart >= start && eventStart < end) || (eventStart < end && eventEnd > start)
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                let left = lhs.localStart(in: calendar)
                let right = rhs.localStart(in: calendar)
                if left != right { return left < right }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}

/// The agenda's scroll to its highlighted row, keyed by day and row.
struct AgendaScrollKey: Hashable {
    let day: Date
    let rowID: String?
}

/// The scroll runs once per day (spec §9.2), the first time the day has a
/// highlighted row: a return from a pushed screen, or the next meeting
/// taking over while the user reads, must not snap the list; a snapshot
/// that highlights a row later still scrolls to it.
enum AgendaScroll {
    static func target(for key: AgendaScrollKey, scrolledDay: Date?) -> String? {
        key.day == scrolledDay ? nil : key.rowID
    }
}

// MARK: - Week strip

/// Seven days starting on today, paged by seven (the page holding the
/// selected day), so the first page shows what is coming rather than the
/// calendar week; today is filled in the accent colour.
struct WeekStripModel {
    struct Day: Identifiable, Equatable {
        let date: Date
        let letter: String
        let number: String
        let isToday: Bool
        let isSelected: Bool
        let hasEvents: Bool
        /// "Wednesday, October 7, today, has events".
        let spokenLabel: String
        var id: Date { date }
    }

    let days: [Day]

    /// `eventDays` holds the start of each local day that has events.
    init(selected: Date, today: Date, eventDays: Set<Date>, calendar: Calendar) {
        let selectedStart = calendar.startOfDay(for: selected)
        let todayStart = calendar.startOfDay(for: today)
        // Calendar days, not 24 h steps, so a DST change keeps the pages aligned.
        let daysFromToday = calendar.dateComponents([.day], from: todayStart, to: selectedStart).day ?? 0
        let pageOffset = Int((Double(daysFromToday) / 7).rounded(.down)) * 7
        let first = calendar.date(byAdding: .day, value: pageOffset, to: todayStart) ?? todayStart
        // Indexed by weekday: 1 = Sunday … 7 = Saturday.
        let letters = ["S", "M", "T", "W", "T", "F", "S"]
        let format = CalendarFormat(calendar: calendar)
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: first) ?? first
            let isToday = calendar.isDate(date, inSameDayAs: today)
            let hasEvents = eventDays.contains(date)
            return Day(
                date: date,
                letter: letters[calendar.component(.weekday, from: date) - 1],
                number: String(calendar.component(.day, from: date)),
                isToday: isToday,
                isSelected: calendar.isDate(date, inSameDayAs: selectedStart),
                hasEvents: hasEvents,
                spokenLabel: ([format.spokenDay(date)] + (isToday ? ["today"] : []) + (hasEvents ? ["has events"] : []))
                    .joined(separator: ", ")
            )
        }
    }

    /// The local days that have at least one event.
    static func eventDays(_ events: [CalendarEvent], calendar: Calendar) -> Set<Date> {
        var days = Set<Date>()
        for event in events {
            var day = calendar.startOfDay(for: event.localStart(in: calendar))
            let end = event.localEnd(in: calendar)
            // An event spanning days marks each; a guard caps a bad range.
            for _ in 0..<31 {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day), next < end else { break }
                day = next
            }
        }
        return days
    }
}
