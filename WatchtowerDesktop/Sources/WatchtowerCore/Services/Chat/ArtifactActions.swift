import Foundation

/// What an artifact button does. A value, not an effect: only the App-side
/// `ArtifactActionPerformer` turns it into a pasteboard write / URL open.
/// There is deliberately no case that sends anything (CHAT-05).
package enum ArtifactAction: Equatable, Sendable {
    case open(URL)
    case copyThenOpen(text: String, url: URL?)
    case copy(String)
}

package struct ArtifactMenuItem: Equatable, Sendable {
    package let title: String
    package let systemImage: String
    package let action: ArtifactAction
}

/// Pure builders: "open ready, never send" (spec §7.2).
package enum ArtifactActions {
    /// Browsers and Gmail start misbehaving past ~8k; above it the body goes
    /// to the clipboard and compose opens without it — never truncated.
    package static let maxURLLength = 8000

    /// RFC 3986 unreserved only. NOT `.alphanumerics` — that set contains
    /// Unicode letters, which would leave Cyrillic unencoded.
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func encode(_ value: String) -> String {
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

    static func addresses(_ raw: String?) -> [String] {
        (raw ?? "")
            .split { $0 == "," || $0 == ";" || $0.isWhitespace }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func withBody(head: String, separator: String, bodyParam: String, body: String) -> ArtifactAction {
        let full = body.isEmpty ? head : head + separator + bodyParam + "=" + encode(body)
        if full.count < maxURLLength, let url = URL(string: full) { return .open(url) }
        return .copyThenOpen(text: body, url: URL(string: head))
    }

    package static func gmailComposeURL(meta: [String: String], body: String) -> ArtifactAction {
        let params = query([("to", meta["to"]), ("cc", meta["cc"]), ("su", meta["subject"])])
        let head = "https://mail.google.com/mail/?view=cm&fs=1" + (params.isEmpty ? "" : "&" + params)
        return withBody(head: head, separator: "&", bodyParam: "body", body: body)
    }

    package static func mailtoURL(meta: [String: String], body: String) -> ArtifactAction {
        let to = addresses(meta["to"]).map(encode).joined(separator: ",")
        let params = query([("cc", meta["cc"]), ("subject", meta["subject"])])
        let head = "mailto:" + to + (params.isEmpty ? "" : "?" + params)
        return withBody(head: head, separator: params.isEmpty ? "?" : "&", bodyParam: "body", body: body)
    }

    /// `meta["title"]` is the event title; start/end are ISO 8601 (offset,
    /// `Z`, local `yyyy-MM-ddTHH:mm[:ss]` in `timeZone`, or a date for all-day;
    /// an all-day `end` is inclusive). No end → one hour.
    package static func calendarTemplateURL(meta: [String: String], body: String, timeZone: TimeZone = .current) -> ArtifactAction {
        let params = query([
            ("text", meta["title"]),
            ("dates", calendarDates(start: meta["start"], end: meta["end"], timeZone: timeZone)),
            ("location", meta["location"]),
            ("add", addresses(meta["attendees"]).joined(separator: ","))
        ])
        let head = "https://calendar.google.com/calendar/render?action=TEMPLATE" + (params.isEmpty ? "" : "&" + params)
        return withBody(head: head, separator: "&", bodyParam: "details", body: body)
    }

    /// Permalink (Slack hosts / `slack:` only) wins; else the stored channel id
    /// (+ `thread_ts`) through the per-account resolver, or the web
    /// archives/app_redirect links when no resolver is at hand. `#name` → nil.
    package static func slackTarget(meta: [String: String], links: SlackLinkResolver? = nil) -> URL? {
        if let raw = meta["permalink"], let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), isSlackURL(url) {
            return url
        }
        guard let channel = meta["channel"]?.trimmingCharacters(in: .whitespaces), !channel.isEmpty, !channel.hasPrefix("#") else {
            return nil
        }
        let ts = meta["thread_ts"].flatMap { $0.isEmpty ? nil : $0 }
        if let links { return links.channelURL(channel, messageTS: ts) }
        if let ts { return SlackDeepLink.archives(channelID: channel, messageTS: ts) }
        return SlackDeepLink.channelRedirect(channelID: channel)
    }

    package static func kindActions(
        for draft: ArtifactDraft, gmailConnected: Bool, slackLinks: SlackLinkResolver?, timeZone: TimeZone = .current
    ) -> [ArtifactMenuItem] {
        switch draft.kind {
        case "email":
            let mail = ArtifactMenuItem(title: "Open in Mail", systemImage: "envelope",
                                        action: mailtoURL(meta: draft.meta, body: draft.content))
            guard gmailConnected else { return [mail] }
            let gmail = ArtifactMenuItem(title: "Open in Gmail", systemImage: "envelope.badge",
                                         action: gmailComposeURL(meta: draft.meta, body: draft.content))
            return [gmail, mail]
        case "slack":
            return [ArtifactMenuItem(title: "Copy & open in Slack", systemImage: "number",
                                     action: .copyThenOpen(text: draft.content, url: slackTarget(meta: draft.meta, links: slackLinks)))]
        case "event":
            var meta = draft.meta
            meta["title"] = draft.title
            return [ArtifactMenuItem(title: "Open in Google Calendar", systemImage: "calendar.badge.plus",
                                     action: calendarTemplateURL(meta: meta, body: draft.content, timeZone: timeZone))]
        default:
            return []
        }
    }

    package static func exportFile(for draft: ArtifactDraft) -> (name: String, contents: String) {
        let base = ArtifactParser.slug(draft.title)
        switch draft.kind {
        case "table":
            return ("\(base).csv", draft.content)
        case "code":
            return ("\(base).\(codeExtension(draft.meta["language"]))", draft.content)
        case "email":
            return ("\(base).txt", header([("To", draft.meta["to"]), ("Cc", draft.meta["cc"]), ("Subject", draft.meta["subject"])]) + draft.content)
        case "event":
            return ("\(base).txt", header([("Title", draft.title), ("Start", draft.meta["start"]), ("End", draft.meta["end"]),
                                           ("Attendees", draft.meta["attendees"]), ("Location", draft.meta["location"])]) + draft.content)
        case "slack":
            return ("\(base).txt", draft.content)
        default:
            return ("\(base).md", draft.content)
        }
    }

    private static func header(_ fields: [(String, String?)]) -> String {
        let lines = fields.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(name): \(value)"
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n\n"
    }

    private static func codeExtension(_ language: String?) -> String {
        switch language?.lowercased() {
        case "swift": return "swift"
        case "go": return "go"
        case "python", "py": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "sql": return "sql"
        case "bash", "sh", "shell", "zsh": return "sh"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        default: return "txt"
        }
    }

    static func isSlackURL(_ url: URL) -> Bool {
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
