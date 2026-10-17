import XCTest
@testable import WatchtowerCore

final class LocalPreviewRoutingTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("local-preview-\(UUID().uuidString)")
        root = base.appendingPathComponent("deck")
        outside = base.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "<h1>Deck</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body{}".write(to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("img/logo one.png"))
        try "TOKEN=x".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("keys.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func get(_ target: String, method: String = "GET", sources: [String: LocalPreviewSource]) -> LocalPreviewResponse {
        LocalPreviewHTTP.respond(to: LocalPreviewRequest(method: method, target: target)) { sources[$0] }
    }

    // MARK: parsing

    func testParseWaitsForTheEndOfTheHeaders() {
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a/b.css?v=1 HTTP/1.1\r\nHost: x\r\n\r\n".utf8)),
                       .request(LocalPreviewRequest(method: "GET", target: "/a/b.css?v=1")))
    }

    func testParseRejectsMalformedAndOversizedRequests() {
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .malformed)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a\r\n\r\n".utf8)), .malformed)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a HTTP/2\r\n\r\n".utf8)), .malformed)
        let huge = Data(("GET /" + String(repeating: "a", count: LocalPreviewHTTP.maxHeaderBytes + 1)).utf8)
        XCTAssertEqual(LocalPreviewHTTP.parse(huge), .malformed)
    }

    // MARK: routing

    func testServesAFileUnderTheRootWithItsContentType() {
        let sources = ["tok": LocalPreviewSource.folder(root)]
        let css = get("/tok/style.css", sources: sources)
        XCTAssertEqual(css.status, 200)
        XCTAssertEqual(css.header("Content-Type"), "text/css; charset=utf-8")
        XCTAssertEqual(css.body, Data("body{}".utf8))
        XCTAssertEqual(css.header("Referrer-Policy"), "no-referrer")
        let png = get("/tok/img/logo%20one.png", sources: sources)
        XCTAssertEqual(png.status, 200)
        XCTAssertEqual(png.header("Content-Type"), "image/png")
        XCTAssertEqual(get("/tok/", sources: sources).body, Data("<h1>Deck</h1>".utf8))
        XCTAssertEqual(get("/tok/index.html#slide-2", sources: sources).status, 200)
    }

    func testWrongOrMissingTokenIsNotFound() {
        let sources = ["tok": LocalPreviewSource.folder(root)]
        XCTAssertEqual(get("/other/index.html", sources: sources).status, 404)
        XCTAssertEqual(get("/index.html", sources: sources).status, 404)
        XCTAssertEqual(get("/", sources: sources).status, 404)
    }

    func testOnlyGetAndHeadAreAllowed() {
        let sources = ["tok": LocalPreviewSource.folder(root)]
        for method in ["POST", "PUT", "DELETE", "OPTIONS", "get"] {
            let response = get("/tok/index.html", method: method, sources: sources)
            XCTAssertEqual(response.status, 405, method)
            XCTAssertEqual(response.header("Allow"), "GET, HEAD")
        }
        let head = get("/tok/index.html", method: "HEAD", sources: sources)
        XCTAssertEqual(head.status, 200)
        let wire = String(bytes: head.serialized(includeBody: false), encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: 13\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"), "HEAD carries no body")
    }

    func testPathTraversalNeverLeavesTheRoot() {
        let sources = ["tok": LocalPreviewSource.folder(root)]
        for target in ["/tok/../secret/keys.txt", "/tok/%2E%2E/secret/keys.txt", "/tok/img/../../secret/keys.txt",
                       "/tok/..%2Fsecret%2Fkeys.txt", "/tok/.env", "/tok/%2Eenv", "/tok//style.css", "/tok/img/",
                       "/tok/img", "/tok/missing.html", "/tok/a%00b"] {
            XCTAssertEqual(get(target, sources: sources).status, 404, target)
        }
    }

    func testBrokenPercentEncodingIsABadRequest() {
        XCTAssertEqual(get("/tok/%zz", sources: ["tok": .folder(root)]).status, 400)
    }

    func testSymlinkEscapingTheRootIsRefused() throws {
        let link = root.appendingPathComponent("leak.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.appendingPathComponent("keys.txt"))
        let dirLink = root.appendingPathComponent("up")
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: outside)
        let inside = root.appendingPathComponent("alias.css")
        try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: root.appendingPathComponent("style.css"))
        let sources = ["tok": LocalPreviewSource.folder(root)]
        XCTAssertEqual(get("/tok/leak.txt", sources: sources).status, 404)
        XCTAssertEqual(get("/tok/up/keys.txt", sources: sources).status, 404)
        XCTAssertEqual(get("/tok/alias.css", sources: sources).status, 200, "a link that stays inside is fine")
    }

    func testAPageIsServedAsIndexWithAStrictPolicy() {
        let sources = ["tok": LocalPreviewSource.page("<p>hi</p>")]
        let page = get("/tok/", sources: sources)
        XCTAssertEqual(page.status, 200)
        XCTAssertEqual(page.body, Data("<p>hi</p>".utf8))
        XCTAssertEqual(page.header("Content-Type"), "text/html; charset=utf-8")
        let policy = try? XCTUnwrap(page.header("Content-Security-Policy"))
        XCTAssertTrue(policy?.hasPrefix("default-src 'none'") ?? false)
        XCTAssertFalse(policy?.contains("connect-src") ?? true, "no fetch/XHR/WebSocket allowance")
        XCTAssertEqual(get("/tok/index.html", sources: sources).status, 200)
        XCTAssertEqual(get("/tok/other.js", sources: sources).status, 404)
    }

    // MARK: registry

    func testRegistryKeepsATokenPerIDAndForgetsOnUnregister() {
        var registry = LocalPreviewRegistry()
        let first = registry.register(id: "chat:1:deck", source: .page("v1"))
        let again = registry.register(id: "chat:1:deck", source: .page("v2"))
        let other = registry.register(id: "chat:1:other", source: .page("x"))
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(registry.source(token: first), .page("v2"))
        registry.unregister(id: "chat:1:deck")
        XCTAssertNil(registry.source(token: first))
        XCTAssertNotNil(registry.source(token: other))
    }

    func testContentTypes() {
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "HTM"), "text/html; charset=utf-8")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "svg"), "image/svg+xml")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "woff2"), "font/woff2")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "bin"), "application/octet-stream")
    }
}
