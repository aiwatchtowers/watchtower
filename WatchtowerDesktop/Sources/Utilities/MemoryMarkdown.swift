import Foundation

/// Pure parsing helpers for vault markdown files: frontmatter split and
/// wiki-link handling. Mirrors the Go side (internal/memory/node.go) — same
/// fence convention, same `[[id]]` / `[[id|label]]` link regex — but stays
/// tolerant where Go is strict: the browser must render a file the pipeline
/// would quarantine, so a malformed frontmatter degrades to "whole file is
/// body" instead of an error.
enum MemoryMarkdown {

    /// Custom URL scheme carrying wiki-link taps out of rendered markdown.
    static let linkScheme = "watchtower-memory"

    // swiftlint:disable:next force_try
    private static let wikiLinkRegex = try! NSRegularExpression(
        pattern: #"\[\[([^\[\]|]+)(?:\|([^\[\]|]*))?\]\]"#
    )

    /// Splits a vault file into its YAML frontmatter (fence contents, no
    /// fences) and markdown body. A file without a well-formed fence pair
    /// comes back as ("", raw) so it still renders.
    static func splitFrontmatter(_ raw: String) -> (frontmatter: String, body: String) {
        let fence = "---\n"
        guard raw.hasPrefix(fence) else { return ("", raw) }
        let rest = String(raw.dropFirst(fence.count))
        guard let closeRange = rest.range(of: "\n" + fence) else { return ("", raw) }
        let frontmatter = String(rest[..<closeRange.lowerBound])
        let body = String(rest[closeRange.upperBound...])
        return (frontmatter, body)
    }

    /// All wiki-link occurrences in a body, in order, duplicates preserved.
    static func parseWikiLinks(_ body: String) -> [MemoryWikiLink] {
        let ns = body as NSString
        let matches = wikiLinkRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        return matches.map { m in
            let target = ns.substring(with: m.range(at: 1))
            let label = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            return MemoryWikiLink(target: target, label: label)
        }
    }

    /// Rewrites `[[target|label]]` occurrences into markdown links on the
    /// `watchtower-memory://` scheme so the house markdown renderer makes them
    /// tappable. `display` chooses the visible text for a link (label wins,
    /// then a resolved title, then the raw target); a nil return leaves the
    /// occurrence as plain `target` text (unresolvable link — no dead taps).
    static func convertWikiLinks(
        in body: String,
        display: (MemoryWikiLink) -> String?
    ) -> String {
        let ns = body as NSString
        let matches = wikiLinkRegex.matches(in: body, range: NSRange(location: 0, length: ns.length))
        var result = body
        for m in matches.reversed() {
            let target = ns.substring(with: m.range(at: 1))
            let label = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
            let link = MemoryWikiLink(target: target, label: label)
            let replacement: String
            if let text = display(link), let url = linkURL(for: target) {
                replacement = "[\(escapeLinkText(text))](\(url))"
            } else {
                replacement = label.isEmpty ? target : label
            }
            guard let range = Range(m.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// Builds the tap URL for a wiki-link target. The target rides in the
    /// path, strictly percent-encoded — alias targets like "situation:23"
    /// would parse as host:port if placed in the authority.
    static func linkURL(for target: String) -> String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.")
        guard let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return "\(linkScheme)://open/\(encoded)"
    }

    /// Extracts the wiki-link target from a `watchtower-memory://` URL.
    static func linkTarget(from url: URL) -> String? {
        guard url.scheme == linkScheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let path = components.path // percent-decoded
        guard path.hasPrefix("/") else { return nil }
        let target = String(path.dropFirst())
        return target.isEmpty ? nil : target
    }

    /// Square brackets inside link text would terminate the markdown link early.
    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }
}
