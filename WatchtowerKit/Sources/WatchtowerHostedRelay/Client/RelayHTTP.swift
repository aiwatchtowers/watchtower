import Foundation
import os

/// The client's HTTPS seam: `URLSessionRelayHTTP` in production, a scripted
/// stub in tests. Headers carry the session token, so a conformer never logs them.
public protocol RelayHTTP: Sendable {
    /// `POST /v1/op`: the status and the whole body, whatever the status.
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data)
    /// An attachment upload (`PUT` of `file` to a presigned URL); returns the status.
    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int
    /// An attachment download to `file`, refused past `maxBytes`; returns the
    /// status. Only a 2xx body is written.
    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int
}

/// `RelayHTTP` over `URLSession`, with the Go client's 30 s request timeout. Every request
/// carries a task delegate that decides its redirects: `POST /v1/op` follows none (the 3xx is
/// the answer, and fails), a blob GET or PUT follows the Go `checkRedirect` rule.
public struct URLSessionRelayHTTP: RelayHTTP {
    /// The Go client's `http.Client{Timeout: 30 * time.Second}`.
    public static let requestTimeout: TimeInterval = 30

    private let session: URLSession

    public init(session: URLSession = Self.ephemeralSession) {
        self.session = session
    }

    /// No disk cache: relay bodies carry envelopes, which the Kit never writes to disk.
    public static let ephemeralSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = Self.request(url, method: "POST", headers: headers)
        request.httpBody = body
        let (data, response) = try await session.data(for: request, delegate: NoRedirects())
        return (try Self.status(response), data)
    }

    public func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        let request = Self.request(url, method: "PUT", headers: headers)
        let (_, response) = try await session.upload(for: request, fromFile: file, delegate: BlobRedirects())
        return try Self.status(response)
    }

    /// Streams the body into `file` and stops with `URLError(.dataLengthExceedsMaximum)`
    /// (removing what it wrote) as soon as it passes `maxBytes`.
    public func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        let request = Self.request(url, method: "GET", headers: headers)
        let (bytes, response) = try await session.bytes(for: request, delegate: BlobRedirects())
        let status = try Self.status(response)
        guard (200..<300).contains(status) else { return status }
        if response.expectedContentLength > maxBytes { throw URLError(.dataLengthExceedsMaximum) }

        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw URLError(.cannotCreateFile) }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var written: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(Self.chunk)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count == Self.chunk {
                    written += Int64(buffer.count)
                    if written > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            written += Int64(buffer.count)
            if written > maxBytes { throw URLError(.dataLengthExceedsMaximum) }
            try handle.write(contentsOf: buffer)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return status
    }

    private static let chunk = 64 * 1024

    private static func request(_ url: URL, method: String, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = method
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    private static func status(_ response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }
}

/// `POST /v1/op`: no redirect is followed, so a 3xx comes back as the final status.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// A blob GET or PUT, the Go `checkRedirect` (`internal/hub/transport/relay/attachments.go`):
/// at most `maxRequests` requests in all (two redirects), and every hop HTTPS or plain HTTP to
/// loopback. A redirect past the rule is not followed: its 3xx comes back and fails.
private final class BlobRedirects: NSObject, URLSessionTaskDelegate {
    /// Go's `maxRedirects`, which counts the requests already made (`len(via)`).
    static let maxRequests = 3

    private let requests = OSAllocatedUnfairLock(initialState: 1)

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let made = requests.withLock { made in
            defer { made += 1 }
            return made
        }
        guard made < Self.maxRequests, let url = request.url, Self.allowedHop(url) else { return completionHandler(nil) }
        completionHandler(request)
    }

    /// HTTPS, or plain HTTP to this machine only (the local stand).
    static func allowedHop(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return RelayLoopback.contains(url)
        default: return false
        }
    }
}

/// The hosts plain HTTP may reach for blobs and their redirects: this machine.
enum RelayLoopback {
    static func contains(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }
}
