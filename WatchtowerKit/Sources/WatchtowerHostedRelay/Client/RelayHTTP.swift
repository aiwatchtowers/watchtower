import Foundation

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

/// `RelayHTTP` over `URLSession`, with the Go client's 30 s request timeout.
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
        let (data, response) = try await session.data(for: request)
        return (try Self.status(response), data)
    }

    public func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int {
        let request = Self.request(url, method: "PUT", headers: headers)
        let (_, response) = try await session.upload(for: request, fromFile: file)
        return try Self.status(response)
    }

    /// Streams the body into `file` and stops with `URLError(.dataLengthExceedsMaximum)`
    /// (removing what it wrote) as soon as it passes `maxBytes`.
    public func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int {
        let request = Self.request(url, method: "GET", headers: headers)
        let (bytes, response) = try await session.bytes(for: request)
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
