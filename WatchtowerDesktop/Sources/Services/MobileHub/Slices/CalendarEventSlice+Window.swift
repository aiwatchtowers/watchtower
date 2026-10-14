import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

extension CalendarEventSlice {
    // MARK: - Window and dedup

    /// Every event id the calendar window holds (each copy of a
    /// de-duplicated event included): `meeting_transcript` publishes the
    /// transcripts of these events whatever their age (spec §4.11).
    static func windowEventIDs(_ db: Database, now: Date, calendar: Calendar) throws -> Set<String> {
        let groups = try windowEvents(db, window: window(now: now, calendar: calendar), calendar: calendar, columns: windowColumns)
        return Set(groups.flatMap(\.members))
    }

    /// The columns the window, the dedup and the order read (no text
    /// column a payload needs): enough for `windowEventIDs`.
    private static let windowColumns = "id, start_time, end_time, is_all_day, conference_url, ical_uid"

    private static let payloadColumns = """
        id, title, description, location, start_time, end_time, organizer_email, attendees,
        is_recurring, is_all_day, event_status, html_link, conference_url, ical_uid
        """

    struct Group {
        var event: CalendarEvent
        /// Every copy's id, the published one first.
        var members: [String]
        /// `localStart(event)`, computed once: the sort compares it, and
        /// `CalendarEvent.startDate` parses ISO 8601 on every call.
        var start: Date
    }

    static func windowEvents(
        _ db: Database,
        window: (start: Date, end: Date),
        calendar: Calendar,
        columns: String = payloadColumns
    ) throws -> [Group] {
        // A day of slack on each side for all-day rows (stored as UTC
        // midnight); the exact test runs below on local dates.
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(columns)
            FROM calendar_events
            WHERE event_status != 'cancelled' AND start_time <= ? AND end_time >= ?
            """, arguments: [
                SliceDate.stamp(window.end.addingTimeInterval(86_400)),
                SliceDate.stamp(window.start.addingTimeInterval(-86_400))
            ])
        var groups: [Group] = []
        var byKey: [String: Int] = [:]
        // Lowest id first, so a later copy replaces the kept one only for a
        // conference link.
        let sorted = rows.map { row in
            let event = CalendarEvent(row: row)
            return (event: event, uid: row["ical_uid"] as String? ?? "", start: localStart(event, calendar: calendar))
        }
            .filter { inWindow($0.event, start: $0.start, window: window, calendar: calendar) }
            .sorted { $0.event.id < $1.event.id }
        for (event, uid, start) in sorted {
            let group = Group(event: event, members: [event.id], start: start)
            guard !uid.isEmpty else {
                groups.append(group)
                continue
            }
            let key = uid + "\u{0}" + event.startTime
            guard let index = byKey[key] else {
                byKey[key] = groups.count
                groups.append(group)
                continue
            }
            if groups[index].event.conferenceURL.isEmpty, !event.conferenceURL.isEmpty {
                groups[index].event = event
                groups[index].start = group.start
                groups[index].members.insert(event.id, at: 0)
            } else {
                groups[index].members.append(event.id)
            }
        }
        groups.sort { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.event.id < rhs.event.id
        }
        return Array(groups.prefix(maxEvents))
    }

    /// Overlap with the window: a timed event by its instants (end
    /// inclusive, as `fetchEvents`), an all-day event by its local days
    /// (end exclusive, as stored).
    /// `start` is `localStart(event)`, computed by the caller.
    private static func inWindow(
        _ event: CalendarEvent,
        start: Date,
        window: (start: Date, end: Date),
        calendar: Calendar
    ) -> Bool {
        guard event.isAllDay else {
            return start <= window.end && event.endDate >= window.start
        }
        let end = localMidnight(ofUTCDay: event.endDate, in: calendar)
        return start <= window.end && end > window.start
    }

    private static func localStart(_ event: CalendarEvent, calendar: Calendar) -> Date {
        event.isAllDay ? localMidnight(ofUTCDay: event.startDate, in: calendar) : event.startDate
    }

    /// Local midnight of the UTC calendar day `instant` falls on (the Kit
    /// mirror's `localStart(in:)` rule).
    private static func localMidnight(ofUTCDay instant: Date, in calendar: Calendar) -> Date {
        guard instant != .distantPast else { return .distantPast }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        let day = utc.dateComponents([.year, .month, .day], from: instant)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .distantPast
    }
}
