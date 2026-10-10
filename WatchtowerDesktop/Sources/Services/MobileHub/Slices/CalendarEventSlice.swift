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

    /// Every event id the calendar window holds (each copy of a
    /// de-duplicated event included): `meeting_transcript` publishes the
    /// transcripts of these events whatever their age (spec §4.11).
    static func windowEventIDs(_ db: Database, now: Date, calendar: Calendar) throws -> Set<String> {
        Set(try windowEvents(db, window: window(now: now, calendar: calendar), calendar: calendar).flatMap(\.members))
    }

    // MARK: - Window and dedup

    private struct Group {
        var event: CalendarEvent
        /// Every copy's id, the published one first.
        var members: [String]
    }

    private static func windowEvents(
        _ db: Database,
        window: (start: Date, end: Date),
        calendar: Calendar
    ) throws -> [Group] {
        // A day of slack on each side for all-day rows (stored as UTC
        // midnight); the exact test runs below on local dates.
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title, description, location, start_time, end_time, organizer_email, attendees,
                   is_recurring, is_all_day, event_status, html_link, conference_url, ical_uid
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
        let sorted = rows.map { (event: CalendarEvent(row: $0), uid: $0["ical_uid"] as String? ?? "") }
            .filter { inWindow($0.event, window: window, calendar: calendar) }
            .sorted { $0.event.id < $1.event.id }
        for (event, uid) in sorted {
            guard !uid.isEmpty else {
                groups.append(Group(event: event, members: [event.id]))
                continue
            }
            let key = uid + "\u{0}" + event.startTime
            guard let index = byKey[key] else {
                byKey[key] = groups.count
                groups.append(Group(event: event, members: [event.id]))
                continue
            }
            if groups[index].event.conferenceURL.isEmpty, !event.conferenceURL.isEmpty {
                groups[index].event = event
                groups[index].members.insert(event.id, at: 0)
            } else {
                groups[index].members.append(event.id)
            }
        }
        groups.sort { lhs, rhs in
            let left = localStart(lhs.event, calendar: calendar)
            let right = localStart(rhs.event, calendar: calendar)
            return left != right ? left < right : lhs.event.id < rhs.event.id
        }
        return Array(groups.prefix(maxEvents))
    }

    /// Overlap with the window: a timed event by its instants (end
    /// inclusive, as `fetchEvents`), an all-day event by its local days
    /// (end exclusive, as stored).
    private static func inWindow(_ event: CalendarEvent, window: (start: Date, end: Date), calendar: Calendar) -> Bool {
        guard event.isAllDay else {
            return event.startDate <= window.end && event.endDate >= window.start
        }
        let start = localStart(event, calendar: calendar)
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

    // MARK: - Prep and linked targets

    private struct Prep {
        let bullets: [String]
        let generatedAt: String
    }

    private struct PrepResult: Decodable {
        struct TalkingPoint: Decodable { let text: String? }
        let talkingPoints: [TalkingPoint]?
        let suggestedPrep: [String]?

        enum CodingKeys: String, CodingKey {
            case talkingPoints = "talking_points"
            case suggestedPrep = "suggested_prep"
        }
    }

    /// event id → its `meeting_prep_cache` bullets. An empty `result_json`
    /// is no prep; an unreadable one is logged and left out.
    private static func prep(_ db: Database, eventIDs: [String]) throws -> [String: Prep] {
        guard !eventIDs.isEmpty else { return [:] }
        var out: [String: Prep] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT event_id, result_json, generated_at FROM meeting_prep_cache
            WHERE result_json != '' AND event_id IN (\(placeholders(eventIDs.count)))
            """, arguments: StatementArguments(eventIDs)) {
            let eventID: String = row["event_id"]
            let json: String = row["result_json"]
            let result: PrepResult
            do {
                result = try JSONDecoder().decode(PrepResult.self, from: Data(json.utf8))
            } catch {
                warnOnce(.prep, id: eventID, event: eventID, content: json, error: error)
                continue
            }
            let bullets = (result.talkingPoints ?? []).compactMap(\.text) + (result.suggestedPrep ?? [])
            out[eventID] = Prep(
                bullets: bullets.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                generatedAt: row["generated_at"]
            )
        }
        return out
    }

    /// event id → the targets converted from its transcripts' chapter action
    /// items (`converted_target_id`), oldest transcript first. Not on a board
    /// only (`project_id IS NULL`, PROJ-01); a deleted target drops out.
    private static func linkedTargets(_ db: Database, eventIDs: [String]) throws -> [String: [LinkedTarget]] {
        guard !eventIDs.isEmpty else { return [:] }
        var converted: [(event: String, target: Int64)] = []
        for row in try Row.fetchAll(db, sql: """
            SELECT id, event_id, chapters_json FROM meeting_transcripts
            WHERE chapters_json IS NOT NULL AND chapters_json != '' AND event_id IN (\(placeholders(eventIDs.count)))
            ORDER BY created_at, id
            """, arguments: StatementArguments(eventIDs)) {
            let json: String = row["chapters_json"]
            let chapters: MeetingChapters
            do {
                chapters = try JSONDecoder().decode(MeetingChapters.self, from: Data(json.utf8))
            } catch {
                warnOnce(.chapters, id: String(row["id"] as Int64), event: row["event_id"], content: json, error: error)
                continue
            }
            let event: String = row["event_id"]
            for item in chapters.chapters.flatMap(\.actionItems) {
                if let target = item.convertedTargetID { converted.append((event, target)) }
            }
        }
        let targetIDs = Array(Set(converted.map(\.target)))
        guard !targetIDs.isEmpty else { return [:] }
        var targets: [Int64: LinkedTarget] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT id, text, status FROM targets
            WHERE project_id IS NULL AND id IN (\(placeholders(targetIDs.count)))
            """, arguments: StatementArguments(targetIDs)) {
            let id: Int64 = row["id"]
            targets[id] = LinkedTarget(id: id, text: SliceClip.text(row["text"], limit: 200).text, status: row["status"])
        }
        var out: [String: [LinkedTarget]] = [:]
        for (event, id) in converted {
            if let target = targets[id] { out[event, default: []].append(target) }
        }
        return out
    }

    /// The lists in order, each target once.
    private static func union(_ lists: [[LinkedTarget]]) -> [LinkedTarget] {
        var seen: Set<Int64> = []
        return lists.joined().filter { seen.insert($0.id).inserted }
    }

    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
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

    // MARK: - Warnings

    enum Unreadable: String {
        case prep = "meeting prep"
        case attendees
        case chapters = "chapters_json"
    }

    /// Logs an unreadable source once per row and content: the 10 s tick
    /// re-reads it, and a changed value warns again. `event` is the
    /// calendar event the row belongs to.
    private static func warnOnce(_ what: Unreadable, id: String, event: String, content: String, error: Error) {
        let key = warnKey(what, id: id, content: content)
        guard warned.withLock({ $0.updateValue(event, forKey: key) == nil }) else { return }
        logger.warning(
            "unreadable \(what.rawValue, privacy: .public) on \(id, privacy: .public) left out: \(String(describing: error), privacy: .public)"
        )
    }

    /// Whether `warnOnce` logged this row's content (the test seam).
    static func hasWarned(_ what: Unreadable, id: String, content: String) -> Bool {
        warned.withLock { $0[warnKey(what, id: id, content: content)] != nil }
    }

    /// Keeps the warn-once set bounded: only the warnings of events still
    /// in the window are remembered.
    private static func forgetWarnings(keeping events: Set<String>) {
        warned.withLock { $0 = $0.filter { events.contains($0.value) } }
    }

    /// How many distinct warnings are remembered for `event`'s rows (the test seam).
    static func warningCount(event: String) -> Int {
        warned.withLock { $0.values.filter { $0 == event }.count }
    }

    private static func warnKey(_ what: Unreadable, id: String, content: String) -> String {
        "\(what.rawValue)\u{0}\(id)\u{0}\(content.hashValue)"
    }

    /// Warning key → the event its row belongs to.
    private static let warned = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    private static let logger = Logger(subsystem: Constants.bundleID, category: "CalendarEventSlice")
}
