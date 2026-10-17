import Foundation

/// What one registration of the loopback preview server serves.
package enum LocalPreviewSource: Equatable, Sendable {
    /// Files under this folder (a workbench html file's own folder).
    case folder(URL)
    /// One in-memory page, served as `index.html` (a chat html artifact).
    case page(String)
}

/// The registrations of the loopback preview server: each has its own
/// random, unguessable token, the first path segment of every URL it serves.
/// Registering the same id again keeps its token (a browser tab refreshes
/// onto the new content) and replaces what it serves.
package struct LocalPreviewRegistry: Sendable {
    private var sources: [String: LocalPreviewSource] = [:]
    private var tokens: [String: String] = [:]

    package init() {}

    @discardableResult
    package mutating func register(id: String, source: LocalPreviewSource) -> String {
        let token = tokens[id] ?? Self.newToken()
        tokens[id] = token
        sources[token] = source
        return token
    }

    package mutating func unregister(id: String) {
        guard let token = tokens.removeValue(forKey: id) else { return }
        sources[token] = nil
    }

    package func source(token: String) -> LocalPreviewSource? { sources[token] }

    package var isEmpty: Bool { sources.isEmpty }

    /// 32 random bytes from the system CSPRNG, hex.
    package static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

/// A parsed HTTP request line: only what routing needs.
package struct LocalPreviewRequest: Equatable, Sendable {
    package let method: String
    package let target: String

    package init(method: String, target: String) {
        self.method = method
        self.target = target
    }
}

package enum LocalPreviewParse: Equatable, Sendable {
    /// The header block has not ended yet.
    case incomplete
    case malformed
    case request(LocalPreviewRequest)
}

package struct LocalPreviewResponse: Equatable, Sendable {
    package let status: Int
    package let headers: [(name: String, value: String)]
    package let body: Data

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body
            && lhs.headers.map { "\($0.name): \($0.value)" } == rhs.headers.map { "\($0.name): \($0.value)" }
    }

    package func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The bytes on the wire; a HEAD response keeps its headers (with the
    /// GET's Content-Length) and drops the body.
    package func serialized(includeBody: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(LocalPreviewHTTP.reason(status))\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if includeBody { data.append(body) }
        return data
    }
}

/// The pure half of the loopback preview server: request parsing, token
/// routing, path resolution and content types. GET and HEAD only, files
/// under the registered root only, no directory listing.
package enum LocalPreviewHTTP {
    /// A request whose header block is bigger is refused.
    package static let maxHeaderBytes = 16 * 1024

    /// A chat artifact's page: inline styles and scripts, data/blob media —
    /// nothing fetched from anywhere, the browser twin of the in-app view's
    /// network block. Its content may come from synced data.
    package static let pageContentSecurityPolicy =
        "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; "
        + "img-src data: blob:; font-src data:; media-src data: blob:; form-action 'none'; base-uri 'none'"

    package static func parse(_ data: Data) -> LocalPreviewParse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .malformed : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8),
              let line = head.components(separatedBy: "\r\n").first else { return .malformed }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .malformed }
        return .request(LocalPreviewRequest(method: String(parts[0]), target: String(parts[1])))
    }

    /// The response to `request`; `lookup` finds a registration by token.
    package static func respond(
        to request: LocalPreviewRequest,
        lookup: (String) -> LocalPreviewSource?,
        fileManager: FileManager = .default
    ) -> LocalPreviewResponse {
        guard request.method == "GET" || request.method == "HEAD" else {
            return error(405, extra: [("Allow", "GET, HEAD")])
        }
        var path = Substring(request.target)
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<cut] }
        var segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let token = segments.first, let source = lookup(token) else { return error(404) }
        segments.removeFirst()
        if segments.isEmpty || segments == [""] { segments = ["index.html"] }
        var decoded: [String] = []
        for segment in segments {
            guard let name = segment.removingPercentEncoding else { return error(400) }
            decoded.append(name)
        }
        switch source {
        case let .page(html):
            guard decoded == ["index.html"] else { return error(404) }
            return ok(Data(html.utf8), type: contentType(forExtension: "html"),
                      extra: [("Content-Security-Policy", pageContentSecurityPolicy)])
        case let .folder(root):
            guard let file = resolve(decoded, under: root, fileManager: fileManager),
                  let data = try? Data(contentsOf: file) else { return error(404) }
            return ok(data, type: contentType(forExtension: file.pathExtension))
        }
    }

    /// The regular file `segments` names under `root`, or nil: no empty,
    /// `.`/`..` or hidden (dot) segment, no separator or NUL inside one, and
    /// once every symlink is resolved the file still lies under the resolved
    /// root. A directory is nil (no listing).
    package static func resolve(_ segments: [String], under root: URL, fileManager: FileManager = .default) -> URL? {
        guard !segments.isEmpty else { return nil }
        for segment in segments {
            guard !segment.isEmpty, !segment.hasPrefix("."),
                  !segment.contains("/"), !segment.contains("\\"), !segment.contains("\0") else { return nil }
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var candidate = base
        for segment in segments { candidate.appendPathComponent(segment) }
        let resolved = candidate.resolvingSymlinksInPath()
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard resolved.path.hasPrefix(basePath) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    package static func contentType(forExtension ext: String) -> String {
        contentTypes[ext.lowercased()] ?? "application/octet-stream"
    }

    private static let contentTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "htm": "text/html; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "js": "text/javascript; charset=utf-8", "mjs": "text/javascript; charset=utf-8",
        "json": "application/json; charset=utf-8", "map": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8", "md": "text/plain; charset=utf-8", "csv": "text/plain; charset=utf-8",
        "xml": "application/xml; charset=utf-8",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "avif": "image/avif", "ico": "image/x-icon",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
        "mp4": "video/mp4", "m4v": "video/mp4", "webm": "video/webm",
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg",
        "pdf": "application/pdf", "wasm": "application/wasm"
    ]

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }

    /// Never cached, never sniffed, and the token never leaks in a Referer
    /// to a site the page links to.
    private static let common: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Connection", "close")
    ]

    private static func ok(_ body: Data, type: String, extra: [(String, String)] = []) -> LocalPreviewResponse {
        let headers = [("Content-Type", type), ("Content-Length", String(body.count))] + extra + common
        return LocalPreviewResponse(status: 200, headers: headers.map { (name: $0.0, value: $0.1) }, body: body)
    }

    package static func error(_ status: Int, extra: [(String, String)] = []) -> LocalPreviewResponse {
        let body = Data("\(status) \(reason(status))\n".utf8)
        let headers = [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.count))] + extra + common
        return LocalPreviewResponse(status: status, headers: headers.map { (name: $0.0, value: $0.1) }, body: body)
    }
}
