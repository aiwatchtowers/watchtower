import Foundation

/// The rules of the sandboxed in-app HTML view (html chat artifacts and the
/// workbench html preview, board #535). HTML there may come from synced data
/// through a prompt injection, so the page gets JavaScript but no bridge to
/// the app and no way to leave its own content. A chat artifact gets no
/// network at all; a workbench file preview gets its folder's visible files
/// through the `scheme` handler and only scripts, style sheets, fonts and
/// images from the CDN allowlist (`cdnHosts`, #563) — never fetch/XHR,
/// sockets, media, documents or any other host.
package enum HTMLPreviewPolicy {
    /// The only hosts a workbench html file may load from, in the app and in
    /// the browser (#563): the common CDNs a deck uses, and Google Fonts.
    /// Everything else external is blocked and named in a banner
    /// (`HTMLBlockedResources`); nothing is fetched on the page's behalf.
    package static let cdnHosts = [
        "cdn.jsdelivr.net", "cdnjs.cloudflare.com", "unpkg.com", "fonts.googleapis.com", "fonts.gstatic.com"
    ]

    /// What a workbench file preview may load from a CDN.
    package static let cdnResourceTypes = ["script", "style-sheet", "font", "image"]

    /// The URL scheme a workbench file preview is served under in the app
    /// (#563): `wtpreview://preview/<path below the folder>`. Its handler
    /// serves only what `previewFile` resolves — the folder's own files, no
    /// hidden one, none through a symlink out or into a hidden one — the same
    /// rules the browser's loopback server applies.
    package static let scheme = "wtpreview"
    package static let host = "preview"

    /// WebKit content rules: block every load, then let back in only what
    /// stays on the machine — `about:`/`data:`/`blob:` always. A chat
    /// artifact gets nothing else: no network of any scheme. A workbench file
    /// preview also gets its own `scheme` (whose handler refuses hidden files)
    /// and https subresources of type script, style sheet, font and image
    /// from the `cdnHosts` only. Fetch/XHR, WebSocket, media, raw loads,
    /// documents over the network and every other host stay blocked, and
    /// http/ws and `file:` never load. (Content-rule regexes have no `|`,
    /// hence one rule per scheme and per host.)
    package static func contentRules(allowFiles: Bool) -> String {
        var allowed = ["^about:", "^data:", "^blob:"]
        if allowFiles { allowed.append("^\(scheme):") }
        var rules = [#"{"trigger":{"url-filter":".*"},"action":{"type":"block"}}"#]
        rules += allowed.map { #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"ignore-previous-rules"}}"# }
        if allowFiles {
            let types = cdnResourceTypes.map { "\"\($0)\"" }.joined(separator: ",")
            rules += cdnHosts.map { host in
                let filter = jsonEscaped("^https://" + regexEscaped(host) + "/")
                return #"{"trigger":{"url-filter":"\#(filter)","resource-type":[\#(types)]},"action":{"type":"ignore-previous-rules"}}"#
            }
        }
        return "[" + rules.joined(separator: ",") + "]"
    }

    /// The preview URL of `file` (under `folder`): each path component below
    /// the folder percent-encoded, `%` included. Nil when `file` is not
    /// under `folder`.
    package static func pageURL(file: URL, folder: URL) -> URL? {
        let base = folder.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(["/", "?", "#", "%", ";"])
        let segments = path.dropFirst(prefix.count).split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        guard !segments.isEmpty, !segments.contains("") else { return nil }
        return URL(string: "\(scheme)://\(host)/" + segments.joined(separator: "/"))
    }

    /// The real file a preview request for `url` may be served from, or nil:
    /// the `scheme`/`host` only, each path segment percent-decoded, then
    /// `LocalPreviewHTTP.resolve` — no `..` or hidden segment, and once every
    /// symlink is resolved the file still lies under the folder with no
    /// hidden component below it (a `notes.js` linking to `.secrets/…` or a
    /// folder link to `.git` is refused).
    package static func previewFile(for url: URL, folder: URL, fileManager: FileManager = .default) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var segments: [String] = []
        for raw in components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            guard let name = String(raw).removingPercentEncoding else { return nil }
            segments.append(name)
        }
        return LocalPreviewHTTP.resolve(segments, under: folder, fileManager: fileManager)
    }

    /// The byte range a `Range: bytes=a-b` header asks of a body of
    /// `length` bytes (media seek), clamped to it; nil for no header, a
    /// malformed or multi-range one, or one past the end (the whole body
    /// is sent then).
    package static func byteRange(_ header: String?, length: Int) -> Range<Int>? {
        guard let header, header.lowercased().hasPrefix("bytes="), length > 0 else { return nil }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return nil }
        let first = spec[..<dash], last = spec[spec.index(after: dash)...]
        if first.isEmpty {
            guard let suffix = Int(last), suffix > 0 else { return nil }
            return max(0, length - suffix)..<length
        }
        guard let start = Int(first), start < length else { return nil }
        if last.isEmpty { return start..<length }
        guard let end = Int(last), end >= start else { return nil }
        return start..<min(end + 1, length)
    }

    /// Whether the view may navigate to `url`. An in-memory page (`page`
    /// nil) stays on `about:` documents (it is `about:blank`, an iframe's
    /// `srcdoc` is `about:srcdoc`). A file preview stays on its own `page`
    /// (any fragment), and a frame inside it may show another file of the
    /// preview `scheme` with no hidden (dot) segment (#563; the handler
    /// resolves symlinks). Every other navigation — a clicked link,
    /// `location = …`, a form — is cancelled: links open nothing.
    package static func allowsNavigation(to url: URL?, isMainFrame: Bool, page: URL?) -> Bool {
        guard let url, let urlScheme = url.scheme?.lowercased() else { return false }
        if urlScheme == "about" { return true }
        guard let page, urlScheme == scheme, url.host?.lowercased() == host else { return false }
        if withoutFragment(url) == withoutFragment(page) { return true }
        guard !isMainFrame, let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            return false
        }
        return !path.split(separator: "/").contains { ($0.removingPercentEncoding ?? ".").hasPrefix(".") }
    }

    /// Html and htm files get a Preview in the code viewer.
    package static func isHTMLFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "html" || ext == "htm"
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
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.string ?? url.absoluteString
    }
}
