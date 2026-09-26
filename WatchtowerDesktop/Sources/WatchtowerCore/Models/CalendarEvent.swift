import Foundation
import GRDB

// MARK: - Attendee

package struct EventAttendee: Codable, Identifiable, Equatable {
    // Note: uses email as identity; assumes no duplicate emails per event (standard for calendar APIs)
    package var id: String { email }
    package let email: String
    package let displayName: String
    package let responseStatus: String
    package let slackUserID: String

    package init(email: String, displayName: String, responseStatus: String, slackUserID: String) {
        self.email = email
        self.displayName = displayName
        self.responseStatus = responseStatus
        self.slackUserID = slackUserID
    }

    package enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
        case responseStatus = "response_status"
        case slackUserID = "slack_user_id"
    }
}

// MARK: - CalendarCalendarItem

package struct CalendarCalendarItem: FetchableRecord, Identifiable, Equatable {
    package let id: String
    package let name: String
    package let isPrimary: Bool
    package let isSelected: Bool
    package let color: String
    package let syncedAt: String
    /// The Google account that synced this calendar, or nil for a CalDAV/ICS
    /// calendar (`caldav:%`/`ics:%` ids), which isn't tied to any account.
    package let accountID: Int?

    package init(row: Row) {
        id = row["id"]
        name = row["name"] ?? ""
        isPrimary = (row["is_primary"] as Int? ?? 0) != 0
        isSelected = (row["is_selected"] as Int? ?? 1) != 0
        color = row["color"] ?? ""
        syncedAt = row["synced_at"] ?? ""
        accountID = row["account_id"]
    }
}

// MARK: - CalendarEvent

package struct CalendarEvent: FetchableRecord, Identifiable, Equatable {
    package let id: String
    package let calendarID: String
    package let title: String
    package let description: String
    package let location: String
    package let startTime: String       // ISO8601
    package let endTime: String         // ISO8601
    package let organizerEmail: String
    package let attendees: String       // JSON array
    package let isRecurring: Bool
    package let isAllDay: Bool
    package let eventStatus: String
    package let eventType: String
    package let htmlLink: String
    package let conferenceURL: String
    package let rawJSON: String
    package let syncedAt: String
    package let updatedAt: String
    /// Email of the Google account that owns this event's calendar, resolved by
    /// a LEFT JOIN in `CalendarQueries` (`calendar_id` → `calendar_calendars`
    /// → `google_accounts`). nil for CalDAV/ICS calendars (no owning account)
    /// and for queries that don't join it. Used only to hint the right account
    /// on a Google Meet join link — see `joinURL`.
    package let accountEmail: String?

    package init(row: Row) {
        id = row["id"]
        calendarID = row["calendar_id"] ?? ""
        title = row["title"] ?? ""
        description = row["description"] ?? ""
        location = row["location"] ?? ""
        startTime = row["start_time"] ?? ""
        endTime = row["end_time"] ?? ""
        organizerEmail = row["organizer_email"] ?? ""
        attendees = row["attendees"] ?? "[]"
        isRecurring = (row["is_recurring"] as Int? ?? 0) != 0
        isAllDay = (row["is_all_day"] as Int? ?? 0) != 0
        eventStatus = row["event_status"] ?? "confirmed"
        eventType = row["event_type"] ?? ""
        htmlLink = row["html_link"] ?? ""
        conferenceURL = row["conference_url"] ?? ""
        rawJSON = row["raw_json"] ?? "{}"
        syncedAt = row["synced_at"] ?? ""
        updatedAt = row["updated_at"] ?? ""
        accountEmail = row["account_email"]
    }

    // MARK: - ISO8601 Parsing

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    // MARK: - Computed Dates

    package var startDate: Date {
        Self.iso8601Formatter.date(from: startTime) ?? Date.distantPast
    }

    package var endDate: Date {
        Self.iso8601Formatter.date(from: endTime) ?? Date.distantPast
    }

    package var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    // MARK: - Attendees

    // Note: decodes JSON each time; acceptable for current use (row rendering, attendee count)
    package var parsedAttendees: [EventAttendee] {
        guard let data = attendees.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EventAttendee].self, from: data)) ?? []
    }

    /// Everyone identified with the event: attendees plus the organizer —
    /// the sync stores the organizer in its own column, never in the
    /// attendees JSON, and an organizer-not-guest event (Zoom/Calendly, a
    /// self-removed organizer) would otherwise lose them. Used to scope
    /// voice-print matching and to seed the rename picker; the organizer
    /// entry is skipped when already listed as an attendee
    /// (case-insensitive email compare).
    ///
    /// Room resources are filtered out FIRST — Google stores them as
    /// ordinary attendee rows (the client parses no resource flag; the
    /// `@resource.calendar.google.com` address is the stable marker, and
    /// the Google client is the only writer of this JSON), and one filter
    /// here covers all three consumers: the sentinel below, the voice-print
    /// scoping set, and the rename picker (a room must never be offered as
    /// a speaker or mint a voice print).
    ///
    /// The organizer joins only a NON-EMPTY (human) attendee list: an empty
    /// result is the "no identities → treat as ad-hoc" sentinel downstream
    /// (`VoicePrintMatcher.scoped` falls back to the global pool on []),
    /// and a zero-guest self-created event (focus block), a room-only
    /// booking, or an undecodable attendees JSON must keep that fallback —
    /// an owner-only set would silently narrow the pool to the owner and
    /// strip every colleague's name.
    package var attendeesIncludingOrganizer: [EventAttendee] {
        let attendees = parsedAttendees.filter {
            let email = $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !email.hasSuffix("@resource.calendar.google.com")
        }
        let organizer = organizerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attendees.isEmpty, !organizer.isEmpty,
              !attendees.contains(where: {
                  $0.email.trimmingCharacters(in: .whitespacesAndNewlines)
                      .caseInsensitiveCompare(organizer) == .orderedSame
              })
        else { return attendees }
        return attendees + [EventAttendee(
            email: organizer, displayName: "", responseStatus: "", slackUserID: "")]
    }

    // MARK: - Conference Link

    /// The event's meeting link (Meet/Zoom/Teams/Webex) as a URL, or nil when
    /// absent or malformed — a bad value in the DB must mean "no Join button",
    /// never a crash.
    package var conferenceLink: URL? {
        guard !conferenceURL.isEmpty,
              let url = URL(string: conferenceURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    /// The link the Join button actually opens. Identical to `conferenceLink`
    /// except for Google Meet: the browser opens `meet.google.com` under its
    /// DEFAULT signed-in account (`authuser=0`), which for someone signed into
    /// both a personal and a work account is usually the wrong one. When we
    /// know the account that owns this event's calendar (`accountEmail`), we
    /// append `?authuser=<email>` so Meet lands on the right account. Only
    /// `meet.google.com` understands `authuser`; Zoom/Teams/Webex — and any
    /// Meet link on a calendar with no owning account (CalDAV/ICS, or a query
    /// that didn't join it) — are opened verbatim. An existing `authuser` is
    /// left untouched.
    package var joinURL: URL? {
        guard let link = conferenceLink else { return nil }
        guard link.host?.lowercased() == "meet.google.com",
              let email = accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty,
              var comps = URLComponents(url: link, resolvingAgainstBaseURL: false)
        else { return link }
        var items = comps.queryItems ?? []
        guard !items.contains(where: { $0.name == "authuser" }) else { return link }
        items.append(URLQueryItem(name: "authuser", value: email))
        comps.queryItems = items
        return comps.url ?? link
    }

    // MARK: - Status

    package var isHappeningNow: Bool {
        let now = Date()
        return now >= startDate && now < endDate
    }

    package var isUpcoming: Bool {
        let now = Date()
        return startDate > now && startDate <= now.addingTimeInterval(3600)
    }

    // MARK: - Description

    package var plainDescription: String {
        Self.stripHTML(description)
    }

    package static func stripHTML(_ input: String) -> String {
        guard !input.isEmpty else { return "" }
        var s = input
        s = s.replacingOccurrences(of: "(?i)<\\s*br\\s*/?\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</\\s*p\\s*>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</\\s*div\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</\\s*li\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<\\s*hr\\s*/?\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let entities: [String: String] = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Display

    package var formattedTimeRange: String {
        if isAllDay { return "All day" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: startDate)) - \(fmt.string(from: endDate))"
    }

    package var durationText: String {
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "\(hours)h" }
        return "\(hours)h \(rem)m"
    }

    package var responseIcon: String {
        switch eventStatus {
        case "confirmed": return "checkmark.circle.fill"
        case "tentative": return "questionmark.circle"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }

    package var responseColor: String {
        switch eventStatus {
        case "confirmed": return "green"
        case "tentative": return "orange"
        case "cancelled": return "red"
        default: return "secondary"
        }
    }
}
