import Foundation

/// A page or doc the assistant published to the owner's claude.ai account
/// (spec 2026-10-16-chat-claude-ai-tools-design §3.1): a `tool_end` source of
/// kind `claude_ai_published` whose `url` is the published page. The chat
/// renders it as a "Published on claude.ai" card whose only actions open the
/// link in the browser or copy it (CHAT-05) — nothing here sends.
///
/// Fail closed: only `https://claude.ai/<path>` becomes a link. Another
/// scheme or host, a lookalike (`claude.ai.example.com`), credentials, a port
/// or a missing URL yields no card; such a source stays plain text in the
/// sources panel (`SourceLinkResolver`).
package struct PublishedLink: Equatable, Sendable {
    package static let sourceKind = "claude_ai_published"

    package let title: String
    package let url: URL

    /// Only `links(from:)` builds one, so every value holds a permitted URL.
    private init(title: String, url: URL) {
        self.title = title
        self.url = url
    }

    /// The turn's published links in order, one per URL (a page updated
    /// twice in a turn is one card, with its first title).
    package static func links(from sources: [ChatSource]) -> [Self] {
        var seen = Set<String>()
        var links: [Self] = []
        for source in sources where source.kind == sourceKind {
            guard let raw = source.url, let url = URL(string: raw), permits(url),
                  seen.insert(pageKey(url)).inserted else { continue }
            let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            links.append(Self(title: title.isEmpty ? url.absoluteString : title, url: url))
        }
        return links
    }

    /// Whether `url` is a claude.ai page this app may open: scheme `https`,
    /// host exactly `claude.ai` (compared percent-encoded, so `claude%2Eai`
    /// is refused), no user, password or port, and a path past `/`.
    package static func permits(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https",
              parts.percentEncodedHost?.lowercased() == "claude.ai",
              parts.user == nil, parts.password == nil, parts.port == nil
        else { return false }
        return parts.percentEncodedPath.count > 1
    }

    /// One page however its scheme and host are cased (`permits` already
    /// pinned both): the rest of the URL as written.
    private static func pageKey(_ url: URL) -> String {
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return [parts?.percentEncodedPath, parts?.percentEncodedQuery, parts?.percentEncodedFragment]
            .map { $0 ?? "" }.joined(separator: "\u{0}")
    }

    /// Everything the card offers, in button order.
    package var actions: [PublishedLinkAction] { [.open(url), .copy(url.absoluteString)] }
}

/// What a published-link card can do: open the page in the browser or copy
/// its link. There is deliberately no other case (CHAT-05).
package enum PublishedLinkAction: Equatable, Sendable {
    case open(URL)
    case copy(String)
}
