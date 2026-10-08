import Foundation
import WatchtowerKit
import WatchtowerSync

// MARK: - Formatting

/// Calendar strings on the phone's clock (or an injected calendar's, in
/// tests). All-day events are placed with `CalendarEvent.localStart(in:)`.
struct CalendarFormat {
    let calendar: Calendar
    private let clock: DateFormatter
    private let dayLabel: DateFormatter

    init(calendar: Calendar) {
        self.calendar = calendar
        clock = Self.formatter("HH:mm", calendar)
        dayLabel = Self.formatter("EEE, MMM d", calendar)
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

// MARK: - Recording state of one event

/// A small coloured label on an event card.
struct EventPill: Equatable, Identifiable {
    let text: String
    let tone: PhoneTone
    let role: ToneRole
    var id: String { text }
}

/// What the Mac and the phone know about recording one event: the recap,
/// the Mac's progress on a phone recording, or the upload on its way.
struct EventRecordingStatus: Equatable {
    let pills: [EventPill]
    /// The event detail's Recording section text; nil = not recorded yet.
    let text: String?

    static let notRecordedText =
        "Not recorded yet. A recording here is attached to this event; the Mac transcribes it and writes the recap."

    init(event: CalendarEvent, snapshot: CalendarReplicaSnapshot, recordings: PhoneRecordingsSnapshot, now: Date) {
        if let transcript = snapshot.transcript(forEvent: event.id) {
            var pills: [EventPill] = []
            let recap = transcript.summary != nil
            pills.append(EventPill(text: recap ? "Recap ready" : "Transcript ready", tone: .green, role: .status))
            let items = transcript.actionItems.count + (transcript.actionItemsMore ?? 0)
            if items > 0 {
                pills.append(EventPill(text: items == 1 ? "1 action item" : "\(items) action items", tone: .secondary, role: .info))
            }
            self.pills = pills
            text = transcript.summary ?? "Transcript ready"
            return
        }
        // The newest phone recording made for this event (the ledger is
        // newest first).
        guard let recording = recordings.recordings.first(where: { $0.eventID == event.id }) else {
            pills = []
            text = nil
            return
        }
        let pill: EventPill
        if let job = recordings.jobs[recording.id] {
            switch PhoneTranscriptStage(job: job) {
            case let .inProgress(label): pill = EventPill(text: label, tone: .purple, role: .progress)
            case .ready, .notStarted: pill = EventPill(text: "Transcript ready", tone: .green, role: .status)
            case let .failed(message): pill = EventPill(text: message, tone: .red, role: .status)
            }
        } else {
            let stage = PhoneUploadStage(recording: recording, heartbeat: recordings.heartbeat, now: now)
            if case .failed = stage {
                pill = EventPill(text: stage.label, tone: .red, role: .status)
            } else {
                pill = EventPill(text: stage.label, tone: .secondary, role: .info)
            }
        }
        pills = [pill]
        text = pill.text
    }
}

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

// MARK: - Week strip

/// Monday to Sunday around the selected day; today is filled in the
/// accent colour.
struct WeekStripModel {
    struct Day: Identifiable, Equatable {
        let date: Date
        let letter: String
        let number: String
        let isToday: Bool
        let isSelected: Bool
        let hasEvents: Bool
        var id: Date { date }
    }

    let days: [Day]

    /// `eventDays` holds the start of each local day that has events.
    init(selected: Date, today: Date, eventDays: Set<Date>, calendar: Calendar) {
        let selectedStart = calendar.startOfDay(for: selected)
        // weekday: 1 = Sunday … 7 = Saturday; Monday is 0 days back.
        let back = (calendar.component(.weekday, from: selectedStart) + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -back, to: selectedStart) ?? selectedStart
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        days = (0..<7).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: monday) ?? monday
            return Day(
                date: date,
                letter: letters[offset],
                number: String(calendar.component(.day, from: date)),
                isToday: calendar.isDate(date, inSameDayAs: today),
                isSelected: calendar.isDate(date, inSameDayAs: selectedStart),
                hasEvents: eventDays.contains(date)
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

// MARK: - Next meeting (Now tab)

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
