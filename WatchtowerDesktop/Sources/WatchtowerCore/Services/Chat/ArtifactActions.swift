import Foundation
import WatchtowerChatText

/// What an artifact button does. A value, not an effect: only the App-side
/// `ArtifactActionPerformer` turns it into a pasteboard write / URL open.
/// There is deliberately no case that sends anything (CHAT-05).
package enum ChatArtifactAction: Equatable, Sendable {
    case open(URL)
    case copyThenOpen(text: String, url: URL?)
    case copy(String)
}

package struct ArtifactMenuItem: Equatable, Sendable {
    package let title: String
    package let systemImage: String
    package let action: ChatArtifactAction
}

/// Pure builders: "open ready, never send" (spec §7.2).
package enum ArtifactActions {
    /// Browsers and Gmail start misbehaving past ~8k; above it the body goes
    /// to the clipboard and compose opens without it — never truncated.
    /// Mail, calendar and Slack links come from the shared `ArtifactLinks`
    /// (WatchtowerChatText), the one copy the iPhone opens too.
    package static let maxURLLength = ArtifactLinks.maxURLLength

    static func encode(_ value: String) -> String { ArtifactLinks.encode(value) }

    private static func action(_ link: ArtifactLink) -> ChatArtifactAction {
        switch link {
        case let .open(url): .open(url)
        case let .copyThenOpen(text, url): .copyThenOpen(text: text, url: url)
        }
    }

    package static func gmailComposeURL(meta: [String: String], body: String) -> ChatArtifactAction {
        let params = ArtifactLinks.query([("to", meta["to"]), ("cc", meta["cc"]), ("su", meta["subject"])])
        let head = "https://mail.google.com/mail/?view=cm&fs=1" + (params.isEmpty ? "" : "&" + params)
        return action(ArtifactLinks.withBody(head: head, separator: "&", bodyParam: "body", body: body))
    }

    package static func mailtoURL(meta: [String: String], body: String) -> ChatArtifactAction {
        action(ArtifactLinks.mailto(meta: meta, body: body))
    }

    /// `meta["title"]` is the event title; start/end are ISO 8601 (offset,
    /// `Z`, local `yyyy-MM-ddTHH:mm[:ss]` in `timeZone`, or a date for all-day;
    /// an all-day `end` is inclusive). No end → one hour.
    package static func calendarTemplateURL(meta: [String: String], body: String, timeZone: TimeZone = .current) -> ChatArtifactAction {
        action(ArtifactLinks.calendarTemplate(meta: meta, body: body, timeZone: timeZone))
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
        case "html":
            return ("\(base).html", draft.content)
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

    static func isSlackURL(_ url: URL) -> Bool { ArtifactLinks.isSlackURL(url) }
}
