import Foundation
import UniformTypeIdentifiers

/// The answers of the in-app preview's scheme handler (#563), pure: which
/// file and byte range a request gets, or why not, and the headers — the
/// browser server's rules (`LocalPreviewHTTP`) for the app.
package enum HTMLPreviewReply: Equatable, Sendable {
    /// Stream `range` of `file` after a response with `status` and `headers`.
    case file(URL, status: Int, headers: [String: String], range: Range<Int>)
    /// A short refusal (404, 413, 416).
    case refusal(status: Int, headers: [String: String], body: Data)

    package var status: Int {
        switch self {
        case let .file(_, status, _, _), let .refusal(status, _, _): status
        }
    }

    package var headers: [String: String] {
        switch self {
        case let .file(_, _, headers, _), let .refusal(_, headers, _): headers
        }
    }

    /// The reply to a preview request for `url` served from `folder`, with
    /// the request's `Range` header: the file `HTMLPreviewPolicy.previewFile`
    /// resolves, stat'ed before it is read; over `LocalPreviewHTTP.maxFileBytes`
    /// is 413, a range starting past the end 416, a range 206. Only the
    /// top-level page (`isPage`) gets the plain in-app CSP; every other reply
    /// — a framed file above all — is also `sandbox allow-scripts`, an opaque
    /// origin the page cannot read (`contentDocument` is null), so a page
    /// cannot frame a sibling file and read it.
    /// A request whose `Accept` starts with `application/json` (a JSON
    /// module) is refused (406) before the file is looked at.
    package static func reply(
        for url: URL,
        folder: URL,
        range rangeHeader: String?,
        isPage: Bool = false,
        accept: String? = nil,
        fileManager: FileManager = .default
    ) -> Self {
        if let accept, accept.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("application/json") {
            return refusal(406)
        }
        guard let file = HTMLPreviewPolicy.previewFile(for: url, folder: folder, fileManager: fileManager),
              let size = (try? fileManager.attributesOfItem(atPath: file.path))?[.size] as? Int else {
            return refusal(404)
        }
        guard size <= LocalPreviewHTTP.maxFileBytes else { return refusal(413) }
        var headers = common
        headers["Content-Security-Policy"] = isPage
            ? HTMLPreviewPolicy.inAppContentSecurityPolicy : HTMLPreviewPolicy.framedContentSecurityPolicy
        headers["Content-Type"] = contentType(forExtension: file.pathExtension)
        switch HTMLPreviewPolicy.byteRange(rangeHeader, length: size) {
        case .whole:
            headers["Content-Length"] = String(size)
            return .file(file, status: 200, headers: headers, range: 0..<size)
        case let .partial(range):
            headers["Content-Length"] = String(range.count)
            headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
            return .file(file, status: 206, headers: headers, range: range)
        case .unsatisfiable:
            return refusal(416, extra: ["Content-Range": "bytes */\(size)"])
        }
    }

    /// The server's table (text types in UTF-8), plus audio and video by
    /// their system type: the handler answers ranges, so media can seek.
    /// JSON and source maps go out as `text/plain` (with `nosniff`): a JSON
    /// module import (static, dynamic or through an import map) is refused
    /// for any type but JSON, so a page cannot read a sibling's data as a
    /// module (#563) — as with `file:` before.
    package static func contentType(forExtension ext: String) -> String {
        if plainTextExtensions.contains(ext.lowercased()) { return "text/plain; charset=utf-8" }
        let type = LocalPreviewHTTP.contentType(forExtension: ext)
        guard type == "application/octet-stream", let media = UTType(filenameExtension: ext.lowercased()),
              media.conforms(to: .audiovisualContent), let mime = media.preferredMIMEType else { return type }
        return mime
    }

    /// Text a module loader would take as JSON.
    private static let plainTextExtensions: Set<String> = ["json", "map", "jsonld", "webmanifest", "geojson"]

    /// On every reply: a sandboxed in-app CSP (no fetch/XHR, sockets or
    /// workers; subresources from the folder and the CDN allowlist only;
    /// the top-level page alone unsandboxed), never sniffed, never cached.
    private static let common = [
        "Content-Security-Policy": HTMLPreviewPolicy.framedContentSecurityPolicy,
        "X-Content-Type-Options": "nosniff",
        "Cache-Control": "no-store",
        "Accept-Ranges": "bytes"
    ]

    private static func refusal(_ status: Int, extra: [String: String] = [:]) -> Self {
        let body = Data("\(status) \(LocalPreviewHTTP.reason(status))\n".utf8)
        var headers = common.merging(extra) { $1 }
        headers["Content-Type"] = "text/plain; charset=utf-8"
        headers["Content-Length"] = String(body.count)
        return .refusal(status: status, headers: headers, body: body)
    }
}

extension HTMLPreviewPolicy {
    /// The source directives the app and the browser share (#563): scripts,
    /// styles, images and fonts from the page's own origin or the CDN
    /// allowlist; no fetch/XHR, WebSocket or worker (a script cannot read
    /// the folder's files as text); `frames` for frame/child sources;
    /// `allowEval` lets `eval`/`new Function` run (template compilers in a deck).
    package static func sourcePolicy(frames: String, allowEval: Bool = false) -> String {
        let cdns = cdnHosts.map { "https://\($0)" }.joined(separator: " ")
        return "default-src 'self'; script-src 'self' 'unsafe-inline'\(allowEval ? " 'unsafe-eval'" : "") \(cdns); "
            + "style-src 'self' 'unsafe-inline' \(cdns); img-src 'self' data: blob: \(cdns); font-src 'self' data: \(cdns); "
            + "media-src 'self' blob:; connect-src 'none'; frame-src \(frames); child-src \(frames); worker-src 'none'; "
            + "object-src 'none'; form-action 'none'; base-uri 'none'"
    }

    /// The in-app preview's CSP: the browser's, but frames of the page's own
    /// files show (the in-app view has no other origin to protect, so no
    /// `sandbox`), and `eval` runs as it did before #563. That opens no
    /// channel: `connect-src`/`worker-src` stay `'none'` and loads stay on the
    /// folder and the CDN allowlist. The browser keeps it off.
    package static let inAppContentSecurityPolicy = sourcePolicy(frames: "'self'", allowEval: true)

    /// Every preview reply but the top-level page: the same, sandboxed. A
    /// framed file runs in an opaque origin, so the page cannot read it.
    package static let framedContentSecurityPolicy = "sandbox allow-scripts; " + inAppContentSecurityPolicy
}
