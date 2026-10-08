import Foundation
import WatchtowerSync

// MARK: - Wire enums

/// `calendar_events.event_status` as stored. rawValues are wire format; a
/// value a newer Mac writes decodes as an unknown value (`OpenWireValue`).
/// The hub never publishes `cancelled` events (spec §4.10); the value is
/// known only so a mirror can name it.
public struct CalendarEventStatus: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let confirmed = Self(rawValue: "confirmed")
    public static let tentative = Self(rawValue: "tentative")
    public static let cancelled = Self(rawValue: "cancelled")
    public static let knownValues: [Self] = [.confirmed, .tentative, .cancelled]
}

/// A linked target's `targets.status`. Linked targets are never on a board
/// (`project_id IS NULL`, PROJ-01), so the board-only `in_review` is not
/// among the known values; anything else decodes as unknown.
public struct LinkedTargetStatus: OpenWireValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let todo = Self(rawValue: "todo")
    public static let inProgress = Self(rawValue: "in_progress")
    public static let blocked = Self(rawValue: "blocked")
    public static let done = Self(rawValue: "done")
    public static let dismissed = Self(rawValue: "dismissed")
    public static let snoozed = Self(rawValue: "snoozed")
    public static let knownValues: [Self] = [.todo, .inProgress, .blocked, .done, .dismissed, .snoozed]
}

// MARK: - Attendee

/// One attendee reduced to the three keys the hub keeps (spec §4.10).
public struct EventAttendee: Codable, Identifiable, Equatable, Sendable {
    // Email is the identity; calendar APIs list each email once per event.
    public var id: String { email }
    public let email: String
    public let displayName: String
    /// As stored (`accepted`, `declined`, `tentative`, `needsAction`, …).
    public let responseStatus: String

    public init(email: String, displayName: String, responseStatus: String) {
        self.email = email
        self.displayName = displayName
        self.responseStatus = responseStatus
    }
}

// MARK: - Linked target

/// A target created from one of the event's transcript action items,
/// shown read-only (spec §4.10).
public struct LinkedTarget: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    /// At most 200 grapheme clusters, clipped by the hub.
    public let text: String
    public let status: LinkedTargetStatus

    public init(id: Int, text: String, status: LinkedTargetStatus) {
        self.id = id
        self.text = text
        self.status = status
    }
}

// MARK: - CalendarEvent

/// The `calendar_event` DataZone slice (mobile POC spec §4.10), record name
/// `calendar_event-<calendar_events.id>`: a capped projection of one event
/// in the hub's window, never the raw row (`raw_json` stays on the Mac).
///
/// Wire: snake_case, sorted keys (decoded with `RelayCoder`). Times travel
/// as the stored ISO8601 strings, so an all-day event keeps its stored
/// date. A nil optional is an absent key: `<field>_clipped` is present only
/// when the hub clipped the field, `<list>_more` only when it dropped
/// entries, `prep_generated_at` only when the event has prep.
public struct CalendarEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    /// ISO8601, as stored.
    public let startTime: String
    /// ISO8601, as stored.
    public let endTime: String
    public let isAllDay: Bool
    public let isRecurring: Bool
    public let eventStatus: CalendarEventStatus
    public let organizerEmail: String
    public let htmlLink: String
    /// "" when the event has no meeting link.
    public let conferenceURL: String
    /// At most 300.
    public let title: String
    public let titleClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// At most 300.
    public let location: String
    public let locationClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// Plain text (the hub strips HTML), at most 2000.
    public let description: String
    public let descriptionClipped: Bool? // swiftlint:disable:this discouraged_optional_boolean
    /// At most 100.
    public let attendees: [EventAttendee]
    public let attendeesMore: Int?
    /// Talking points, then suggested prep: at most 8, each at most 300.
    public let prepBullets: [String]
    public let prepBulletsMore: Int?
    /// ISO8601, as stored; nil when the event has no prep yet.
    public let prepGeneratedAt: String?
    /// At most 20, read-only.
    public let linkedTargets: [LinkedTarget]
    public let linkedTargetsMore: Int?

    public var recordName: String { SliceKind.calendarEvent.recordName(id: id) }

    // convertFromSnakeCase maps "conference_url" -> "conferenceUrl"
    // (lowercase rl), so that key's stringValue uses this form.
    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, isAllDay, isRecurring, eventStatus, organizerEmail, htmlLink
        case conferenceURL = "conferenceUrl"
        case title, titleClipped, location, locationClipped, description, descriptionClipped
        case attendees, attendeesMore, prepBullets, prepBulletsMore, prepGeneratedAt
        case linkedTargets, linkedTargetsMore
    }

    public init(
        id: String,
        startTime: String,
        endTime: String,
        isAllDay: Bool,
        isRecurring: Bool,
        eventStatus: CalendarEventStatus,
        organizerEmail: String,
        htmlLink: String,
        conferenceURL: String,
        title: String,
        titleClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        location: String,
        locationClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        description: String,
        descriptionClipped: Bool? = nil, // swiftlint:disable:this discouraged_optional_boolean
        attendees: [EventAttendee],
        attendeesMore: Int? = nil,
        prepBullets: [String],
        prepBulletsMore: Int? = nil,
        prepGeneratedAt: String? = nil,
        linkedTargets: [LinkedTarget],
        linkedTargetsMore: Int? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.isAllDay = isAllDay
        self.isRecurring = isRecurring
        self.eventStatus = eventStatus
        self.organizerEmail = organizerEmail
        self.htmlLink = htmlLink
        self.conferenceURL = conferenceURL
        self.title = title
        self.titleClipped = titleClipped
        self.location = location
        self.locationClipped = locationClipped
        self.description = description
        self.descriptionClipped = descriptionClipped
        self.attendees = attendees
        self.attendeesMore = attendeesMore
        self.prepBullets = prepBullets
        self.prepBulletsMore = prepBulletsMore
        self.prepGeneratedAt = prepGeneratedAt
        self.linkedTargets = linkedTargets
        self.linkedTargetsMore = linkedTargetsMore
    }

    // MARK: - Dates

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    /// `startTime` parsed; `distantPast` when malformed. For an all-day
    /// event this is the stored UTC midnight, which falls on the previous
    /// day west of UTC: place and format events with `localStart(in:)`.
    public var startDate: Date {
        Self.iso8601Formatter.date(from: startTime) ?? Date.distantPast
    }

    /// `endTime` parsed; `distantPast` when malformed. All-day: see
    /// `startDate`, use `localEnd(in:)`.
    public var endDate: Date {
        Self.iso8601Formatter.date(from: endTime) ?? Date.distantPast
    }

    /// Where the event starts on `calendar`'s clock. A timed event is its
    /// instant; an all-day event is local midnight of its stored calendar
    /// day (the hub stores the day as UTC midnight), so it never shifts by
    /// a day in a zone west or east of UTC. `distantPast` when malformed.
    public func localStart(in calendar: Calendar) -> Date {
        isAllDay ? Self.localMidnight(ofUTCDay: startDate, in: calendar) : startDate
    }

    /// The end counterpart of `localStart(in:)`; an all-day end is the
    /// exclusive next day, as stored.
    public func localEnd(in calendar: Calendar) -> Date {
        isAllDay ? Self.localMidnight(ofUTCDay: endDate, in: calendar) : endDate
    }

    private static func localMidnight(ofUTCDay instant: Date, in calendar: Calendar) -> Date {
        guard instant != .distantPast else { return .distantPast }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? utc.timeZone
        let day = utc.dateComponents([.year, .month, .day], from: instant)
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) ?? .distantPast
    }

    // MARK: - Conference link

    /// The event's meeting link as a URL, or nil when absent or malformed —
    /// a bad value must mean "no Join button", never a crash.
    public var conferenceLink: URL? {
        guard !conferenceURL.isEmpty,
              let url = URL(string: conferenceURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }
}
