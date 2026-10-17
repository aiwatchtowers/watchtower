import Foundation

/// The rules of the sandboxed in-app HTML view (html chat artifacts and the
/// workbench html preview, board #535). HTML there may come from synced data
/// through a prompt injection, so the page gets JavaScript but no bridge to
/// the app and no way to leave its own content. A chat artifact gets no
/// network at all; a workbench file preview gets only scripts, style sheets,
/// fonts and images from the CDN allowlist (`cdnHosts`, #563) — never
/// fetch/XHR, sockets, media, documents or any other host.
package enum HTMLPreviewPolicy {
    /// The only hosts a workbench html file may load from, in the app and in
    /// the browser (#563): the common CDNs a deck uses, and Google Fonts.
    /// Everything else external is blocked and named in a banner
    /// (`blockedResources`); nothing is fetched on the page's behalf.
    package static let cdnHosts = [
        "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com", "fonts.googleapis.com", "fonts.gstatic.com"
    ]

    /// What a workbench file preview may load from a CDN.
    package static let cdnResourceTypes = ["script", "style-sheet", "font", "image"]

    /// WebKit content rules: block every load, then let back in only the
    /// schemes that stay on the machine — `about:`/`data:`/`blob:` always.
    /// A chat artifact (`folder` nil) gets nothing else: no network of any
    /// scheme. A workbench file preview also gets the `file:` URLs under
    /// `folder` with no hidden (dot) component below it — never `.env` or
    /// `.git/config`, in a frame or as a script (#563) — and https
    /// subresources of type script, style sheet, font and image from the
    /// `cdnHosts` only. Fetch/XHR, WebSocket, media, raw loads, documents
    /// over the network and every other host stay blocked, and http/ws never
    /// load. (Content-rule regexes have no `|`, hence one rule per scheme and
    /// per host.)
    package static func contentRules(folder: URL?) -> String {
        var allowed = ["^about:", "^data:", "^blob:"]
        if let folder { allowed.append(visibleFilesFilter(under: folder)) }
        var rules = [#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#]
        rules += allowed.map { #"{"trigger":{"url-filter":"\#(jsonEscaped($0))"},"action":{"type":"ignore-previous-rules"}}"# }
        if folder != nil {
            let types = cdnResourceTypes.map { "\"\($0)\"" }.joined(separator: ",")
            rules += cdnHosts.map { host in
                let filter = jsonEscaped("^https://" + regexEscaped(host) + "/")
                return #"{"trigger":{"url-filter":"\#(filter)","resource-type":[\#(types)]},"action":{"type":"ignore-previous-rules"}}"#
            }
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// The url-filter of the files a preview of `folder` may load: under the
    /// folder's own URL, every path component below it not starting with a
    /// dot. The folder itself may sit in a hidden folder (a session worktree
    /// under `.claude/worktrees`). Fails closed: a URL WebKit spells
    /// differently from this prefix loads nothing.
    package static func visibleFilesFilter(under folder: URL) -> String {
        var prefix = folder.standardizedFileURL.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        return "^" + regexEscaped(prefix) + "/([^./][^/]*/)*[^./][^/]*$"
    }

    /// Whether the view may navigate to `url`. The page itself (`page`, any
    /// fragment) and `about:` documents (an in-memory page is `about:blank`,
    /// an iframe's `srcdoc` is `about:srcdoc`) are allowed; a frame inside
    /// the page may also show a file under `folder` with no hidden (dot)
    /// component below it (#563). Every other navigation — a clicked link,
    /// `location = …`, a form — is cancelled: links open nothing.
    package static func allowsNavigation(to url: URL?, isMainFrame: Bool, page: URL?, folder: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        if let page, url.isFileURL, page.isFileURL, withoutFragment(url) == withoutFragment(page) { return true }
        if !isMainFrame, url.isFileURL, let folder {
            let base = folder.standardizedFileURL.path
            let prefix = base.hasSuffix("/") ? base : base + "/"
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return false }
            return !path.dropFirst(prefix.count).split(separator: "/").contains { $0.hasPrefix(".") }
        }
        return false
    }

    /// Html and htm files get a Preview in the code viewer.
    package static func isHTMLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    // MARK: blocked external resources (the banner, #563)

    /// The external resources an html file's markup and inline CSS name
    /// that the preview blocks: `total` distinct URLs and their hosts in the
    /// order they first appear. Anything not https on a `cdnHosts` host is
    /// blocked (http, protocol-relative `//host`, any other host). A read
    /// of the source, not of the running page: a URL built by a script is
    /// blocked just the same but not counted. Links (`<a>`, `<area>`) and
    /// form actions are not resources and are not counted.
    package struct BlockedResources: Equatable, Sendable {
        package let total: Int
        package let hosts: [String]

        package init(total: Int, hosts: [String]) {
            self.total = total
            self.hosts = hosts
        }

        /// "Blocked 3 external resources: a.example, b.example, c.example…",
        /// at most `maxHosts` hosts; nil when nothing is blocked.
        package func banner(maxHosts: Int = 3) -> String? {
            guard total > 0 else { return nil }
            let noun = total == 1 ? "resource" : "resources"
            let shown = hosts.prefix(maxHosts).joined(separator: ", ")
            return "Blocked \(total) external \(noun): \(shown)\(hosts.count > maxHosts ? "…" : "")"
        }
    }

    package static func blockedResources(in html: String) -> BlockedResources {
        var seen = Set<String>()
        var hosts: [String] = []
        for reference in resourceReferences(in: html) {
            guard let host = blockedHost(reference), seen.insert(reference).inserted else { continue }
            if !hosts.contains(host) { hosts.append(host) }
        }
        return BlockedResources(total: seen.count, hosts: hosts)
    }

    /// The host `reference` would load from when the preview blocks it; nil
    /// for a local, `data:`/`blob:` or allowlisted reference.
    static func blockedHost(_ reference: String) -> String? {
        let lower = reference.lowercased()
        let external = lower.hasPrefix("//") || lower.hasPrefix("http:") || lower.hasPrefix("https:")
        guard external else { return nil }
        let absolute = lower.hasPrefix("//") ? "https:" + reference : reference
        let host = URLComponents(string: absolute)?.host?.lowercased() ?? ""
        if lower.hasPrefix("https:"), cdnHosts.contains(host) { return nil }
        return host.isEmpty ? "(unknown host)" : host
    }

    /// The URLs named by resource attributes of every tag but `<a>`,
    /// `<area>` and `<form>`, by `srcset` candidates, and by CSS `url(…)`
    /// and `@import`.
    static func resourceReferences(in html: String) -> [String] {
        var references: [String] = []
        for tag in matches(tagPattern, in: html) where !linkTags.contains(tag[1].lowercased()) {
            for attribute in matches(attributePattern, in: tag[2]) {
                let value = attribute[2].isEmpty ? (attribute[3].isEmpty ? attribute[4] : attribute[3]) : attribute[2]
                if attribute[1].lowercased() == "srcset" {
                    references += value.split(separator: ",").compactMap { $0.split(separator: " ").first.map(String.init) }
                } else {
                    references.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        references += matches(cssURLPattern, in: html).map { $0[1] }
        references += matches(importPattern, in: html).map { $0[1] }
        return references
    }

    private static let linkTags: Set<String> = ["a", "area", "form"]
    private static let tagPattern = #"<([a-zA-Z][a-zA-Z0-9-]*)\b([^>]*)>"#
    private static let attributePattern =
        #"(?i)\b(src|srcset|href|poster|data|background)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
    private static let cssURLPattern = #"(?i)url\(\s*["']?([^"')\s]+)"#
    private static let importPattern = #"(?i)@import\s+["']([^"']+)"#

    /// Every match of `pattern`, each as its capture groups (index 0 the
    /// whole match; a group that did not take part is "").
    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    // MARK: helpers

    /// `text` with the regex metacharacters of a content-rule url-filter escaped.
    static func regexEscaped(_ text: String) -> String {
        var out = ""
        for char in text {
            if #"\^$.*+?()[]{}|"#.contains(char) { out.append("\\") }
            out.append(char)
        }
        return out
    }

    private static func jsonEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url.standardizedFileURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.string ?? url.absoluteString
    }
}
