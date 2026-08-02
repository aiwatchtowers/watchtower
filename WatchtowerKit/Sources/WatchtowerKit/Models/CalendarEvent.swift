import Foundation
import GRDB

// MARK: - Attendee

public struct EventAttendee: Codable, Identifiable, Equatable {
    // Note: uses email as identity; assumes no duplicate emails per event (standard for calendar APIs)
    public var id: String { email }
    public let email: String
    public let displayName: String
    public let responseStatus: String
    public let slackUserID: String

    enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
        case responseStatus = "response_status"
        case slackUserID = "slack_user_id"
    }
}

// MARK: - CalendarCalendarItem

public struct CalendarCalendarItem: FetchableRecord, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let isPrimary: Bool
    public let isSelected: Bool
    public let color: String
    public let syncedAt: String
    /// The Google account that synced this calendar, or nil for a CalDAV/ICS
    /// calendar (`caldav:%`/`ics:%` ids), which isn't tied to any account.
    public let accountID: Int?

    public init(row: Row) {
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

public struct CalendarEvent: FetchableRecord, Identifiable, Equatable {
    public let id: String
    public let calendarID: String
    public let title: String
    public let description: String
    public let location: String
    public let startTime: String       // ISO8601
    public let endTime: String         // ISO8601
    public let organizerEmail: String
    public let attendees: String       // JSON array
    public let isRecurring: Bool
    public let isAllDay: Bool
    public let eventStatus: String
    public let eventType: String
    public let htmlLink: String
    public let conferenceURL: String
    public let rawJSON: String
    public let syncedAt: String
    public let updatedAt: String

    public init(row: Row) {
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
    }

    // MARK: - ISO8601 Parsing

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    // MARK: - Computed Dates

    public var startDate: Date {
        Self.iso8601Formatter.date(from: startTime) ?? Date.distantPast
    }

    public var endDate: Date {
        Self.iso8601Formatter.date(from: endTime) ?? Date.distantPast
    }

    public var duration: TimeInterval {
        endDate.timeIntervalSince(startDate)
    }

    // MARK: - Attendees

    // Note: decodes JSON each time; acceptable for current use (row rendering, attendee count)
    public var parsedAttendees: [EventAttendee] {
        guard let data = attendees.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EventAttendee].self, from: data)) ?? []
    }

    // MARK: - Conference Link

    /// The event's meeting link (Meet/Zoom/Teams/Webex) as a URL, or nil when
    /// absent or malformed — a bad value in the DB must mean "no Join button",
    /// never a crash.
    public var conferenceLink: URL? {
        guard !conferenceURL.isEmpty,
              let url = URL(string: conferenceURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    // MARK: - Status

    public var isHappeningNow: Bool {
        let now = Date()
        return now >= startDate && now < endDate
    }

    public var isUpcoming: Bool {
        let now = Date()
        return startDate > now && startDate <= now.addingTimeInterval(3600)
    }

    // MARK: - Description

    public var plainDescription: String {
        Self.stripHTML(description)
    }

    public static func stripHTML(_ input: String) -> String {
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
            "&apos;": "'"
        ]
        for (k, v) in entities {
            s = s.replacingOccurrences(of: k, with: v)
        }
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Display

    public var formattedTimeRange: String {
        if isAllDay { return "All day" }
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm"
        return "\(fmt.string(from: startDate)) - \(fmt.string(from: endDate))"
    }

    public var durationText: String {
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 { return "\(hours)h" }
        return "\(hours)h \(rem)m"
    }

    public var responseIcon: String {
        switch eventStatus {
        case "confirmed": return "checkmark.circle.fill"
        case "tentative": return "questionmark.circle"
        case "cancelled": return "xmark.circle"
        default: return "circle"
        }
    }

    public var responseColor: String {
        switch eventStatus {
        case "confirmed": return "green"
        case "tentative": return "orange"
        case "cancelled": return "red"
        default: return "secondary"
        }
    }
}
