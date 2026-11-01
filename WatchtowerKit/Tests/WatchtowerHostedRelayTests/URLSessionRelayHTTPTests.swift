import Foundation
import os
import WatchtowerHostedRelay
import XCTest

/// The real `URLSessionRelayHTTP` on an ephemeral session whose only protocol is a stub:
/// `POST /v1/op` follows no redirect; blob GET and PUT follow the Go `checkRedirect` rule
/// (at most three requests, each hop HTTPS or plain HTTP to loopback).
final class URLSessionRelayHTTPTests: XCTestCase {
    private var http: URLSessionRelayHTTP!
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        RedirectStubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectStubProtocol.self]
        http = URLSessionRelayHTTP(session: URLSession(configuration: configuration))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("relay-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        RedirectStubProtocol.reset()
        try await super.tearDown()
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    func testOpFollowsNoRedirect() async throws {
        RedirectStubProtocol.route("https://relay.example.com/v1/op", .redirect("https://elsewhere.example.net/v1/op"))
        RedirectStubProtocol.route("https://elsewhere.example.net/v1/op", .ok(Data("followed".utf8)))
        let answer = try await http.post(try url("https://relay.example.com/v1/op"), body: Data("op".utf8), headers: [:])
        XCTAssertEqual(answer.status, 302, "the redirect is the answer")
        XCTAssertEqual(RedirectStubProtocol.seen, ["https://relay.example.com/v1/op"], "never sent to the other host")
    }

    func testBlobGetFollowsTheRedirectRule() async throws {
        let file = directory.appendingPathComponent("blob")

        // To another host over HTTPS: followed.
        RedirectStubProtocol.route("https://blob.example.com/a", .redirect("https://elsewhere.example.net/a"))
        RedirectStubProtocol.route("https://elsewhere.example.net/a", .ok(Data("bytes".utf8)))
        let followed = try await http.get(try url("https://blob.example.com/a"), to: file, maxBytes: 100, headers: [:])
        XCTAssertEqual(followed, 200)
        XCTAssertEqual(try Data(contentsOf: file), Data("bytes".utf8))

        // To another host over plain HTTP: not followed, the 302 is the answer.
        RedirectStubProtocol.reset()
        RedirectStubProtocol.route("https://blob.example.com/b", .redirect("http://elsewhere.example.net/b"))
        RedirectStubProtocol.route("http://elsewhere.example.net/b", .ok(Data("bytes".utf8)))
        let plain = try await http.get(try url("https://blob.example.com/b"), to: file, maxBytes: 100, headers: [:])
        XCTAssertEqual(plain, 302)
        XCTAssertEqual(RedirectStubProtocol.seen, ["https://blob.example.com/b"])

        // Plain HTTP to loopback (the local stand): followed.
        RedirectStubProtocol.reset()
        RedirectStubProtocol.route("https://blob.example.com/c", .redirect("http://127.0.0.1:8787/c"))
        RedirectStubProtocol.route("http://127.0.0.1:8787/c", .ok(Data("local".utf8)))
        let loopback = try await http.get(try url("https://blob.example.com/c"), to: file, maxBytes: 100, headers: [:])
        XCTAssertEqual(loopback, 200)

        // A third redirect (a fourth request) is not followed.
        RedirectStubProtocol.reset()
        for hop in 0..<3 {
            RedirectStubProtocol.route("https://blob.example.com/h\(hop)", .redirect("https://blob.example.com/h\(hop + 1)"))
        }
        RedirectStubProtocol.route("https://blob.example.com/h3", .ok(Data("far".utf8)))
        let far = try await http.get(try url("https://blob.example.com/h0"), to: file, maxBytes: 100, headers: [:])
        XCTAssertEqual(far, 302)
        XCTAssertEqual(RedirectStubProtocol.seen.count, 3, "three requests at most")
    }

    func testBlobPutFollowsTheRedirectRule() async throws {
        let file = directory.appendingPathComponent("upload")
        try Data("sealed".utf8).write(to: file)

        RedirectStubProtocol.route("https://blob.example.com/up", .redirect("http://elsewhere.example.net/up"))
        RedirectStubProtocol.route("http://elsewhere.example.net/up", .ok(Data()))
        let plain = try await http.put(try url("https://blob.example.com/up"), file: file, headers: [:])
        XCTAssertEqual(plain, 302)
        XCTAssertEqual(RedirectStubProtocol.seen, ["https://blob.example.com/up"])

        RedirectStubProtocol.reset()
        RedirectStubProtocol.route("https://blob.example.com/up", .redirect("https://elsewhere.example.net/up"))
        RedirectStubProtocol.route("https://elsewhere.example.net/up", .ok(Data()))
        let followed = try await http.put(try url("https://blob.example.com/up"), file: file, headers: [:])
        XCTAssertEqual(followed, 200)
    }
}

/// Answers from a route table: a 302 with `Location`, or a 200 with a body; 404 otherwise.
final class RedirectStubProtocol: URLProtocol {
    enum Route {
        case redirect(String)
        case ok(Data)
    }

    private struct State {
        var routes: [String: Route] = [:]
        var seen: [String] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func reset() {
        state.withLock { $0 = State() }
    }

    static func route(_ url: String, _ route: Route) {
        state.withLock { $0.routes[url] = route }
    }

    /// Every URL requested, in order.
    static var seen: [String] {
        state.withLock { $0.seen }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let route = Self.state.withLock { state -> Route? in
            state.seen.append(url.absoluteString)
            return state.routes[url.absoluteString]
        }
        switch route {
        case .redirect(let target)?:
            guard let next = URL(string: target),
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target])
            else { return }
            var redirected = URLRequest(url: next)
            redirected.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .ok(let body)?:
            answer(url, status: 200, body: body)
        case nil:
            answer(url, status: 404, body: Data())
        }
    }

    override func stopLoading() {}

    private func answer(_ url: URL, status: Int, body: Data) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
