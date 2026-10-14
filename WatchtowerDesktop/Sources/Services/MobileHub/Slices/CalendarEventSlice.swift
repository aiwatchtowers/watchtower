import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

/// The `calendar_event` slice (mobile POC spec §4.10), record name
/// `calendar_event-<calendar_events.id>`: a capped projection of each event
/// in the window, never the raw row (`raw_json` is not even read).
///
/// Window: events overlapping local today 00:00 − 1 day … now + 14 calendar days
/// (the `CalendarQueries.fetchEvents` overlap rule, so an event running
/// over midnight into the first day is kept), not `cancelled`, ≤ 500,
/// earliest first. An all-day event is placed by its stored calendar day
/// (stored as UTC midnight), read as local midnight, so it neither shifts
/// nor leaks a day west or east of UTC. Same non-empty `ical_uid` and
/// `start_time` (one event on two accounts' calendars) → one record: the
/// copy with a `conference_url`, else the lowest id; prep and linked
/// targets are read across all copies.
///
/// Wire shape: the Kit mirror `WatchtowerKit.CalendarEvent`, RelayCoder
/// JSON; times are the stored ISO8601 strings.
struct CalendarEventSlice: SliceSource {
    let kind = SliceKind.calendarEvent

    static let maxEvents = 500
    static let maxAttendees = 100
    static let maxPrepBullets = 8
    static let maxLinkedTargets = 20
    static let daysAhead = 14

    let now: @Sendable () -> Date
    /// The Mac's calendar; its time zone decides local midnight.
    let calendar: @Sendable () -> Calendar

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { Calendar.current }
    ) {
        self.now = now
        self.calendar = calendar
    }

    struct Attendee: Codable, Equatable {
        let email: String
        let displayName: String
        let responseStatus: String

        enum CodingKeys: String, CodingKey {
            case email
            case displayName = "display_name"
            case responseStatus = "response_status"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? ""
            responseStatus = try container.decodeIfPresent(String.self, forKey: .responseStatus) ?? ""
        }
    }

    struct LinkedTarget: Encodable, Equatable {
        let id: Int64
        let text: String
        let status: String
    }

    struct Payload: Encodable, Equatable {
        let id: String
        let startTime: String
        let endTime: String
        let isAllDay: Bool
        let isRecurring: Bool
        let eventStatus: String
        let organizerEmail: String
        let htmlLink: String
        let conferenceURL: String
        let title: String
        let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let location: String
        let locationClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let description: String
        let descriptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
        let attendees: [Attendee]
        let attendeesMore: Int?
        let prepBullets: [String]
        let prepBulletsMore: Int?
        let prepGeneratedAt: String?
        let linkedTargets: [LinkedTarget]
        let linkedTargetsMore: Int?

        enum CodingKeys: String, CodingKey {
            case id, startTime, endTime, isAllDay, isRecurring, eventStatus, organizerEmail, htmlLink
            case conferenceURL = "conference_url"
            case title, titleClipped, location, locationClipped, description, descriptionClipped
            case attendees, attendeesMore, prepBullets, prepBulletsMore, prepGeneratedAt
            case linkedTargets, linkedTargetsMore
        }
    }

    /// The window bounds: local 00:00 of yesterday (a calendar step, so a
    /// DST change keeps it on midnight) to now + 14 calendar days.
    static func window(now: Date, calendar: Calendar) -> (start: Date, end: Date) {
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        let end = calendar.date(byAdding: .day, value: daysAhead, to: now)
            ?? now.addingTimeInterval(Double(daysAhead) * 86_400)
        return (start, end)
    }

    func records(_ db: Database) throws -> [SliceRecord] {
        let stamp = now()
        let calendar = calendar()
        let window = Self.window(now: stamp, calendar: calendar)
        let groups = try Self.windowEvents(db, window: window, calendar: calendar)
        let ids = groups.flatMap(\.members)
        Self.forgetWarnings(keeping: Set(ids))
        let prep = try Self.prep(db, eventIDs: ids)
        let linked = try Self.linkedTargets(db, eventIDs: ids)
        let encoder = RelayCoder.makeEncoder()
        return try groups.map { group in
            let payload = makePayload(
                group.event,
                prep: group.members.lazy.compactMap { prep[$0] }.first,
                linked: Self.union(group.members.map { linked[$0] ?? [] })
            )
            return SliceRecord(kind: kind, id: group.event.id, modifiedAt: stamp, payload: try encoder.encode(payload))
        }
    }

    // MARK: - Payload

    private func makePayload(_ event: CalendarEvent, prep: Prep?, linked: [LinkedTarget]) -> Payload {
        let title = SliceClip.text(event.title, limit: 300)
        let location = SliceClip.text(event.location, limit: 300)
        let description = SliceClip.text(event.plainDescription, limit: 2000)
        let attendees = SliceClip.list(Self.attendees(event), limit: Self.maxAttendees)
        let bullets = SliceClip.list(prep?.bullets ?? [], limit: Self.maxPrepBullets)
        let targets = SliceClip.list(linked, limit: Self.maxLinkedTargets)
        return Payload(
            id: event.id,
            startTime: event.startTime,
            endTime: event.endTime,
            isAllDay: event.isAllDay,
            isRecurring: event.isRecurring,
            eventStatus: event.eventStatus,
            organizerEmail: event.organizerEmail,
            htmlLink: event.htmlLink,
            conferenceURL: event.conferenceURL,
            title: title.text, titleClipped: title.clipped,
            location: location.text, locationClipped: location.clipped,
            description: description.text, descriptionClipped: description.clipped,
            attendees: attendees.items, attendeesMore: attendees.more,
            prepBullets: bullets.items.map { SliceClip.text($0, limit: 300).text },
            prepBulletsMore: bullets.more,
            prepGeneratedAt: prep?.generatedAt,
            linkedTargets: targets.items, linkedTargetsMore: targets.more
        )
    }

    /// The stored attendees JSON reduced to three keys. `null` (Go's nil
    /// slice, an event without guests) and "" are an empty list; an
    /// unreadable list is logged and published empty.
    private static func attendees(_ event: CalendarEvent) -> [Attendee] {
        let json = event.attendees
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            return try JSONDecoder().decode([Attendee]?.self, from: Data(json.utf8)) ?? []
        } catch {
            warnOnce(.attendees, id: event.id, event: event.id, content: json, error: error)
            return []
        }
    }
}
