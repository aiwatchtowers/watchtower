import Foundation

/// What a workbench html file's markup asks to load that the preview blocks
/// (#563), for the "Blocked …" line over the preview. A read of the source,
/// not of the running page: a URL a script builds is blocked the same way
/// but not counted, and a symlink to a hidden file is refused unseen.
///
/// Counted: the resource attributes (`src`, `srcset`, `poster`,
/// `background`, `<object data>`, and `href` of a `<link>` that loads —
/// a style sheet, icon or preload) of every tag outside comments and the raw
/// text of `<script>`, `<pre>`, `<textarea>`, `<xmp>` and `<noscript>`, plus
/// CSS `url(…)` and `@import`. An external one is blocked unless it is https
/// on a `HTMLPreviewPolicy.cdnHosts` host *and* an allowed type (frames,
/// media and embeds never load from anywhere); a relative one is blocked
/// when a path component is hidden (`.secrets/config.js`).
package struct HTMLBlockedResources: Equatable, Sendable {
    /// Distinct blocked external URLs.
    package let total: Int
    /// Their hosts, in the order they first appear.
    package let hosts: [String]
    /// Distinct relative references into a hidden file or folder.
    package let hiddenFiles: Int

    package init(total: Int, hosts: [String], hiddenFiles: Int = 0) {
        self.total = total
        self.hosts = hosts
        self.hiddenFiles = hiddenFiles
    }

    /// "Blocked 3 external resources: a.example, b.example, c.example… · 1
    /// hidden file", at most `maxHosts` hosts; nil when nothing is blocked.
    package func banner(maxHosts: Int = 3) -> String? {
        var parts: [String] = []
        if total > 0 {
            let shown = hosts.prefix(maxHosts).joined(separator: ", ")
            parts.append("\(total) external \(total == 1 ? "resource" : "resources"): \(shown)\(hosts.count > maxHosts ? "…" : "")")
        }
        if hiddenFiles > 0 {
            parts.append("\(hiddenFiles) hidden \(hiddenFiles == 1 ? "file" : "files")")
        }
        return parts.isEmpty ? nil : "Blocked " + parts.joined(separator: " · ")
    }

    package static func scan(_ html: String) -> Self {
        var external = Set<String>()
        var hosts: [String] = []
        var hidden = Set<String>()
        for reference in references(in: html) {
            if let host = blockedHost(reference.url, typeAllowed: reference.typeAllowed) {
                guard external.insert(reference.url).inserted else { continue }
                if !hosts.contains(host) { hosts.append(host) }
            } else if isHiddenLocal(reference.url) {
                hidden.insert(reference.url)
            }
        }
        return Self(total: external.count, hosts: hosts, hiddenFiles: hidden.count)
    }

    // MARK: classification

    /// The host `url` would load from when the preview blocks it; nil for a
    /// local, `data:`/`blob:` or allowed CDN reference.
    static func blockedHost(_ url: String, typeAllowed: Bool) -> String? {
        let lower = url.lowercased()
        guard lower.hasPrefix("//") || lower.hasPrefix("http:") || lower.hasPrefix("https:") else { return nil }
        let host = URLComponents(string: lower.hasPrefix("//") ? "https:" + url : url)?.host?.lowercased() ?? ""
        if typeAllowed, lower.hasPrefix("https:"), HTMLPreviewPolicy.cdnHosts.contains(host) { return nil }
        return host.isEmpty ? "(unknown host)" : host
    }

    /// A relative reference with a hidden path component (not `.`/`..`).
    static func isHiddenLocal(_ url: String) -> Bool {
        guard !url.contains(":"), !url.hasPrefix("//"), !url.hasPrefix("#") else { return false }
        let path = url.split { $0 == "?" || $0 == "#" }.first ?? ""
        return path.split(separator: "/").contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
    }

    struct Reference: Equatable {
        let url: String
        /// A type the CDN allowlist may serve (script, style, font, image).
        let typeAllowed: Bool
    }

    static func references(in html: String) -> [Reference] {
        let text = stripped(html)
        var out: [Reference] = []
        for tag in matches(tagRegex, in: text) {
            let name = tag[1].lowercased()
            guard !ignoredTags.contains(name) else { continue }
            let attributes = matches(attributeRegex, in: tag[2]).map { (name: $0[1].lowercased(), value: value(of: $0)) }
            for attribute in attributes {
                switch attribute.name {
                case "href":
                    guard name == "link", loadsResource(rel: attributes.first { $0.name == "rel" }?.value) else { continue }
                case "data":
                    guard name == "object" else { continue }
                case "rel":
                    continue
                default:
                    break
                }
                let typeAllowed = !mediaTags.contains(name) || attribute.name == "poster" || (name == "source" && attribute.name == "srcset")
                let urls = attribute.name == "srcset"
                    ? attribute.value.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
                    : [attribute.value.trimmingCharacters(in: .whitespacesAndNewlines)]
                out += urls.filter { !$0.isEmpty }.map { Reference(url: $0, typeAllowed: typeAllowed) }
            }
        }
        out += matches(cssURLRegex, in: text).map { Reference(url: $0[1], typeAllowed: true) }
        out += matches(importRegex, in: text).map { Reference(url: $0[1], typeAllowed: true) }
        return out
    }

    /// The source without comments and without the raw text of elements
    /// whose content never loads anything as markup (their opening tag stays).
    private static func stripped(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        let noComments = commentRegex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
        let range2 = NSRange(noComments.startIndex..., in: noComments)
        return rawTextRegex.stringByReplacingMatches(in: noComments, range: range2, withTemplate: "$1")
    }

    private static func loadsResource(rel: String?) -> Bool {
        let rels = Set((rel ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
        return !rels.isDisjoint(with: loadingRels)
    }

    private static func value(of attribute: [String]) -> String {
        attribute[2].isEmpty ? (attribute[3].isEmpty ? attribute[4] : attribute[3]) : attribute[2]
    }

    /// Links and form actions are not resources; `<base>` only moves them.
    private static let ignoredTags: Set<String> = ["a", "area", "form", "base"]
    /// A `<link rel>` that loads what it names.
    private static let loadingRels: Set<String> = ["stylesheet", "icon", "apple-touch-icon", "preload", "modulepreload", "prefetch"]
    /// Frames, media and embeds: blocked even from an allowlisted CDN.
    private static let mediaTags: Set<String> = ["iframe", "frame", "video", "audio", "source", "track", "embed", "object"]

    private static let tagRegex = compile(#"<([a-zA-Z][a-zA-Z0-9-]*)\b([^>]*)>"#)
    private static let attributeRegex =
        compile(#"(?i)\b(src|srcset|href|poster|data|background|rel)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let cssURLRegex = compile(#"(?i)url\(\s*["']?([^"')\s]+)"#)
    private static let importRegex = compile(#"(?i)@import\s+["']([^"']+)"#)
    private static let commentRegex = compile(#"(?s)<!--.*?-->"#)
    private static let rawTextRegex = compile(#"(?is)(<(script|pre|textarea|xmp|noscript)\b[^>]*>).*?</\2\s*>"#)

    private static func compile(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern)
    }

    /// Every match of `regex`, each as its capture groups (index 0 the whole
    /// match; a group that did not take part is "").
    private static func matches(_ regex: NSRegularExpression, in text: String) -> [[String]] {
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
