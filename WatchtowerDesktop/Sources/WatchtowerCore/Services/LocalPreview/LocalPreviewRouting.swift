import Foundation

/// The registrations of the loopback preview server: each is one folder
/// (a workbench html file's own folder) under its own random, unguessable
/// token, the first path segment of every URL it serves. Registering the
/// same id again keeps its token and replaces the folder.
package struct LocalPreviewRegistry: Sendable {
    private var folders: [String: URL] = [:]
    private var tokens: [String: String] = [:]

    package init() {}

    @discardableResult
    package mutating func register(id: String, folder: URL) -> String {
        let token = tokens[id] ?? Self.newToken()
        tokens[id] = token
        folders[token] = folder
        return token
    }

    package mutating func unregister(id: String) {
        guard let token = tokens.removeValue(forKey: id) else { return }
        folders[token] = nil
    }

    package func folder(token: String) -> URL? { folders[token] }

    /// 32 random bytes from the system CSPRNG, hex.
    package static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

/// A parsed HTTP request: only what routing needs.
package struct LocalPreviewRequest: Equatable, Sendable {
    package let method: String
    package let target: String
    /// The `Host` header, nil when absent.
    package let host: String?

    package init(method: String, target: String, host: String?) {
        self.method = method
        self.target = target
        self.host = host
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

/// The pure half of the loopback preview server: request parsing, the Host
/// check, token routing, path resolution and content types. GET and HEAD
/// only, files under the registered folder only, no directory listing.
package enum LocalPreviewHTTP {
    /// A request whose header block is bigger is refused.
    package static let maxHeaderBytes = 16 * 1024

    /// On every response. `sandbox` without `allow-same-origin` gives the
    /// page an opaque origin: no cookies or storage shared with anything
    /// else on 127.0.0.1, no popups, no forms. `connect-src`/`frame-src`
    /// `'none'`: a script cannot read the folder's other files as text (no
    /// fetch, XHR, WebSocket, frame or worker). Scripts, styles, fonts and
    /// images may still come from the folder or an https CDN (reveal.js
    /// decks); the page can still navigate itself to another site.
    package static let contentSecurityPolicy =
        "sandbox allow-scripts; default-src 'self'; script-src 'self' 'unsafe-inline' https:; "
        + "style-src 'self' 'unsafe-inline' https:; img-src 'self' data: blob: https:; font-src 'self' data: https:; "
        + "media-src 'self' blob:; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; "
        + "object-src 'none'; form-action 'none'; base-uri 'none'"

    package static func parse(_ data: Data) -> LocalPreviewParse {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .malformed : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .malformed }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, parts[1].hasPrefix("/"),
              parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else { return .malformed }
        var host: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Host") == .orderedSame {
                guard host == nil else { return .malformed }
                host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return .request(LocalPreviewRequest(method: String(parts[0]), target: String(parts[1]), host: host))
    }

    /// The response to `request` on a server listening on `port`; `lookup`
    /// finds a registration's folder by token. A Host other than
    /// `127.0.0.1:<port>` or `localhost:<port>` (a DNS-rebinding page) is 403.
    package static func respond(
        to request: LocalPreviewRequest,
        port: UInt16,
        lookup: (String) -> URL?,
        fileManager: FileManager = .default
    ) -> LocalPreviewResponse {
        guard let host = request.host?.lowercased(), host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            return error(403)
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return error(405, extra: [("Allow", "GET, HEAD")])
        }
        var path = Substring(request.target)
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = path[..<cut] }
        var segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let token = segments.first, let root = lookup(token) else { return error(404) }
        segments.removeFirst()
        if segments.isEmpty || segments == [""] { segments = ["index.html"] }
        var decoded: [String] = []
        for segment in segments {
            guard let name = segment.removingPercentEncoding else { return error(400) }
            decoded.append(name)
        }
        guard let file = resolve(decoded, under: root, fileManager: fileManager),
              let data = try? Data(contentsOf: file) else { return error(404) }
        return ok(data, type: contentType(forExtension: file.pathExtension))
    }

    /// The regular file `segments` names under `root`, or nil: no empty,
    /// `.`/`..` or hidden (dot) segment, no separator or NUL inside one; once
    /// every symlink is resolved the file still lies under the resolved root,
    /// and no component of its real path below the root is hidden either (a
    /// symlink to `.env` or `.git/config` is refused). A directory is nil
    /// (no listing).
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
        let below = resolved.path.dropFirst(basePath.count).split(separator: "/")
        guard !below.contains(where: { $0.hasPrefix(".") }) else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return resolved
    }

    package static func contentType(forExtension ext: String) -> String {
        contentTypes[ext.lowercased()] ?? "application/octet-stream"
    }

    /// No video: the server has no Range support, which Safari needs to play
    /// it. Audio plays but may not seek.
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
        "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg",
        "pdf": "application/pdf", "wasm": "application/wasm"
    ]

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }

    /// Never cached, never sniffed, and the token never leaks in a Referer
    /// to a site the page links to.
    private static let common: [(String, String)] = [
        ("Content-Security-Policy", contentSecurityPolicy),
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("Connection", "close")
    ]

    private static func ok(_ body: Data, type: String) -> LocalPreviewResponse {
        let headers = [("Content-Type", type), ("Content-Length", String(body.count))] + common
        return LocalPreviewResponse(status: 200, headers: headers.map { (name: $0.0, value: $0.1) }, body: body)
    }

    package static func error(_ status: Int, extra: [(String, String)] = []) -> LocalPreviewResponse {
        let body = Data("\(status) \(reason(status))\n".utf8)
        let headers = [("Content-Type", "text/plain; charset=utf-8"), ("Content-Length", String(body.count))] + extra + common
        return LocalPreviewResponse(status: status, headers: headers.map { (name: $0.0, value: $0.1) }, body: body)
    }
}
