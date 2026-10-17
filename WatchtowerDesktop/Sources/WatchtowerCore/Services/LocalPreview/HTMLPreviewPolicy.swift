import Foundation

/// The rules of the sandboxed in-app HTML view (html chat artifacts and the
/// workbench html preview, board #535). HTML there may come from synced data
/// through a prompt injection, so the page gets JavaScript but no bridge to
/// the app and no way to leave its own content. A chat artifact gets no
/// network at all; a workbench file preview gets only https scripts, style
/// sheets, fonts and images (CDN decks) — never fetch/XHR, sockets, media
/// or documents.
package enum HTMLPreviewPolicy {
    /// WebKit content rules: block every load, then let back in only the
    /// schemes that stay on the machine — `about:`/`data:`/`blob:` always,
    /// `file:` only for a file preview (WebKit itself keeps it inside the
    /// folder the view was given read access to). A chat artifact (no
    /// files) gets nothing else: no network of any scheme. A workbench file
    /// preview also gets https subresources of type script, style sheet,
    /// font and image (a CDN deck such as reveal.js); fetch/XHR, WebSocket,
    /// media, raw loads and documents over the network stay blocked, and
    /// http/ws never load. (Content-rule regexes have no `|`, hence one rule
    /// per scheme.)
    package static func contentRules(allowFiles: Bool) -> String {
        var schemes = ["about", "data", "blob"]
        if allowFiles { schemes.append("file") }
        var rules = [#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#]
        rules += schemes.map { #"{"trigger":{"url-filter":"^\#($0):"},"action":{"type":"ignore-previous-rules"}}"# }
        if allowFiles {
            rules.append(#"{"trigger":{"url-filter":"^https:","resource-type":["#
                + cdnResourceTypes.map { "\"\($0)\"" }.joined(separator: ",")
                + #"]},"action":{"type":"ignore-previous-rules"}}"#)
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// What a workbench file preview may load over https.
    package static let cdnResourceTypes = ["script", "style-sheet", "font", "image"]

    /// Whether the view may navigate to `url`. The page itself (`page`, any
    /// fragment) and `about:` documents (an in-memory page is `about:blank`,
    /// an iframe's `srcdoc` is `about:srcdoc`) are allowed; a frame inside
    /// the page may also show a file under `folder`. Every other navigation —
    /// a clicked link, `location = …`, a form — is cancelled: links open
    /// nothing.
    package static func allowsNavigation(to url: URL?, isMainFrame: Bool, page: URL?, folder: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return true }
        if let page, url.isFileURL, page.isFileURL, withoutFragment(url) == withoutFragment(page) { return true }
        if !isMainFrame, url.isFileURL, let folder {
            let base = folder.standardizedFileURL.path
            return url.standardizedFileURL.path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        return false
    }

    /// Html and htm files get a Preview in the code viewer.
    package static func isHTMLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url.standardizedFileURL, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.string ?? url.absoluteString
    }
}
