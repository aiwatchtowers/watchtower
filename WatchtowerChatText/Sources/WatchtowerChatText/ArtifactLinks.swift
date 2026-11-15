import Foundation

/// What an artifact's open button does: open a URL, or put the text on the clipboard and then open (a body too
/// long for a URL). There is no case that sends anything (CHAT-05).
public enum ArtifactLink: Equatable, Sendable {
    case open(URL)
    case copyThenOpen(text: String, url: URL?)
}

/// The open-ready links of chat artifacts, shared by the Mac and the iPhone (iPhone chat spec §6.2): `mailto:` for
/// an email, the Google Calendar template URL for an event, a Slack permalink. The Mac's `ArtifactActions` builds
/// the same links (its tests and `ArtifactLinksTests` pin the same cases). Pure.
public enum ArtifactLinks {
    /// Browsers and Gmail start misbehaving past ~8k; above it the body goes to the clipboard and compose opens
    /// without it — never truncated.
    public static let maxURLLength = 8000

    /// RFC 3986 unreserved only: `.alphanumerics` holds Unicode letters, which would leave Cyrillic unencoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    static func query(_ items: [(String, String?)]) -> String {
        items
            .compactMap { name, value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return "\(name)=\(encode(value))"
            }
            .joined(separator: "&")
    }

    public static func addresses(_ raw: String?) -> [String] {
        (raw ?? "")
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func withBody(head: String, separator: String, bodyParam: String, body: String) -> ArtifactLink {
        let full = body.isEmpty ? head : head + separator + bodyParam + "=" + encode(body)
        if full.count < maxURLLength, let url = URL(string: full) { return .open(url) }
        return .copyThenOpen(text: body, url: URL(string: head))
    }

    /// Open in Mail: to (comma, semicolon or space separated), cc, subject and the body.
    public static func mailto(meta: [String: String], body: String) -> ArtifactLink {
        let to = addresses(meta["to"]).map(encode).joined(separator: ",")
        let params = query([("cc", meta["cc"]), ("subject", meta["subject"])])
        let head = "mailto:" + to + (params.isEmpty ? "" : "?" + params)
        return withBody(head: head, separator: params.isEmpty ? "?" : "&", bodyParam: "body", body: body)
    }

    /// `meta["title"]` is the event title; start/end are ISO 8601 (an offset, `Z`, local `yyyy-MM-ddTHH:mm[:ss]` in
    /// `timeZone`, or a date for all day; an all-day `end` is inclusive). No end → one hour.
    public static func calendarTemplate(meta: [String: String], body: String, timeZone: TimeZone = .current) -> ArtifactLink {
        let params = query([
            ("text", meta["title"]),
            ("dates", calendarDates(start: meta["start"], end: meta["end"], timeZone: timeZone)),
            ("location", meta["location"]),
            ("add", addresses(meta["attendees"]).joined(separator: ","))
        ])
        let head = "https://calendar.google.com/calendar/render?action=TEMPLATE" + (params.isEmpty ? "" : "&" + params)
        return withBody(head: head, separator: "&", bodyParam: "details", body: body)
    }

    /// The Slack link a `slack` artifact names: its permalink when that is a Slack URL (`slack:` or a slack.com
    /// host), else Slack's own app.
    public static func slack(meta: [String: String]) -> URL? {
        if let raw = meta["permalink"], let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), isSlackURL(url) {
            return url
        }
        return URL(string: "slack://open")
    }

    public static func isSlackURL(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "slack":
            return true
        case "https":
            guard let host = url.host?.lowercased() else { return false }
            return host == "slack.com" || host.hasSuffix(".slack.com")
        default:
            return false
        }
    }

    static func calendarDates(start: String?, end: String?, timeZone: TimeZone) -> String? {
        guard let start = start?.trimmingCharacters(in: .whitespaces), !start.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        if let day = parseDay(start, timeZone: timeZone) {
            let lastDay = end.flatMap { parseDay($0, timeZone: timeZone) } ?? day
            guard let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: lastDay) else { return nil }
            return format(day, "yyyyMMdd", timeZone) + "/" + format(exclusiveEnd, "yyyyMMdd", timeZone)
        }
        guard let startDate = parseDateTime(start, timeZone: timeZone) else { return nil }
        let endDate = end.flatMap { parseDateTime($0, timeZone: timeZone) } ?? startDate.addingTimeInterval(3600)
        let utc = TimeZone(identifier: "UTC") ?? timeZone
        return format(startDate, "yyyyMMdd'T'HHmmss'Z'", utc) + "/" + format(endDate, "yyyyMMdd'T'HHmmss'Z'", utc)
    }

    private static func parseDay(_ value: String, timeZone: TimeZone) -> Date? {
        guard value.count == 10 else { return nil }
        return formatter("yyyy-MM-dd", timeZone).date(from: value)
    }

    private static func parseDateTime(_ value: String, timeZone: TimeZone) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            if let date = formatter(pattern, timeZone).date(from: value) { return date }
        }
        return nil
    }

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        formatter(pattern, timeZone).string(from: date)
    }
}
