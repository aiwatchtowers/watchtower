import XCTest
@testable import WatchtowerCore

final class LocalPreviewRoutingTests: XCTestCase {
    private var root: URL!
    private var outside: URL!
    private let port: UInt16 = 51_234

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("local-preview-\(UUID().uuidString)")
        root = base.appendingPathComponent("deck")
        outside = base.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "<h1>Deck</h1>".write(to: root.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body{}".write(to: root.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("img/logo one.png"))
        try "TOKEN=x".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "[core]".write(to: root.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("keys.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func get(_ target: String, method: String = "GET", host: String? = nil) -> LocalPreviewResponse {
        let request = LocalPreviewRequest(method: method, target: target, host: host ?? "127.0.0.1:\(port)")
        return LocalPreviewHTTP.respond(to: request, port: port) { $0 == "tok" ? self.root : nil }
    }

    // MARK: parsing

    func testParseWaitsForTheEndOfTheHeadersAndReadsHost() {
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a HTTP/1.1\r\nHost: x\r\n".utf8)), .incomplete)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a/b.css?v=1 HTTP/1.1\r\nhost:  127.0.0.1:9 \r\nAccept: */*\r\n\r\n".utf8)),
                       .request(LocalPreviewRequest(method: "GET", target: "/a/b.css?v=1", host: "127.0.0.1:9")))
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a HTTP/1.0\r\n\r\n".utf8)),
                       .request(LocalPreviewRequest(method: "GET", target: "/a", host: nil)))
    }

    func testParseRejectsMalformedAndOversizedRequests() {
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET http://evil/ HTTP/1.1\r\n\r\n".utf8)), .malformed)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a\r\n\r\n".utf8)), .malformed)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a HTTP/2\r\n\r\n".utf8)), .malformed)
        XCTAssertEqual(LocalPreviewHTTP.parse(Data("GET /a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n".utf8)), .malformed)
        let huge = Data(("GET /" + String(repeating: "a", count: LocalPreviewHTTP.maxHeaderBytes + 1)).utf8)
        XCTAssertEqual(LocalPreviewHTTP.parse(huge), .malformed)
    }

    // MARK: routing

    func testServesAFileUnderTheRootWithItsContentTypeAndTheSandboxPolicy() {
        let css = get("/tok/style.css")
        XCTAssertEqual(css.status, 200)
        XCTAssertEqual(css.header("Content-Type"), "text/css; charset=utf-8")
        XCTAssertEqual(css.body, Data("body{}".utf8))
        XCTAssertEqual(css.header("Referrer-Policy"), "no-referrer")
        let png = get("/tok/img/logo%20one.png")
        XCTAssertEqual(png.status, 200)
        XCTAssertEqual(png.header("Content-Type"), "image/png")
        XCTAssertEqual(get("/tok/").body, Data("<h1>Deck</h1>".utf8))
        XCTAssertEqual(get("/tok/index.html#slide-2").status, 200)
        for response in [css, png, get("/tok/missing"), get("/tok/x", method: "POST"), get("/tok/", host: "evil.example:1")] {
            XCTAssertEqual(response.header("Content-Security-Policy"), LocalPreviewHTTP.contentSecurityPolicy)
        }
    }

    func testThePolicySandboxesAndForbidsReadingSiblingsAsText() {
        let policy = LocalPreviewHTTP.contentSecurityPolicy
        XCTAssertTrue(policy.hasPrefix("sandbox allow-scripts;"))
        XCTAssertFalse(policy.contains("allow-same-origin"))
        XCTAssertFalse(policy.contains("allow-popups"))
        for directive in ["connect-src 'none'", "frame-src 'none'", "child-src 'none'", "worker-src 'none'",
                          "object-src 'none'", "form-action 'none'", "base-uri 'none'"] {
            XCTAssertTrue(policy.contains(directive), directive)
        }
    }

    func testOnlyTheLoopbackHostOfThisPortIsServed() {
        XCTAssertEqual(get("/tok/index.html", host: "localhost:\(port)").status, 200)
        XCTAssertEqual(get("/tok/index.html", host: "LOCALHOST:\(port)").status, 200)
        for host in ["evil.example", "evil.example:\(port)", "127.0.0.1", "127.0.0.1:1", "localhost", "[::1]:\(port)", ""] {
            XCTAssertEqual(get("/tok/index.html", host: host).status, 403, host)
        }
        let noHost = LocalPreviewHTTP.respond(to: LocalPreviewRequest(method: "GET", target: "/tok/", host: nil), port: port) { _ in self.root }
        XCTAssertEqual(noHost.status, 403)
    }

    func testWrongOrMissingTokenIsNotFound() {
        XCTAssertEqual(get("/other/index.html").status, 404)
        XCTAssertEqual(get("/index.html").status, 404)
        XCTAssertEqual(get("/").status, 404)
    }

    func testOnlyGetAndHeadAreAllowed() {
        for method in ["POST", "PUT", "DELETE", "OPTIONS", "get"] {
            let response = get("/tok/index.html", method: method)
            XCTAssertEqual(response.status, 405, method)
            XCTAssertEqual(response.header("Allow"), "GET, HEAD")
        }
        let head = get("/tok/index.html", method: "HEAD")
        XCTAssertEqual(head.status, 200)
        let wire = String(bytes: head.serialized(includeBody: false), encoding: .utf8) ?? ""
        XCTAssertTrue(wire.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(wire.contains("Content-Length: 13\r\n"))
        XCTAssertTrue(wire.hasSuffix("\r\n\r\n"), "HEAD carries no body")
    }

    func testPathTraversalNeverLeavesTheRoot() {
        for target in ["/tok/../secret/keys.txt", "/tok/%2E%2E/secret/keys.txt", "/tok/img/../../secret/keys.txt",
                       "/tok/..%2Fsecret%2Fkeys.txt", "/tok/.env", "/tok/%2Eenv", "/tok/.git/config", "/tok//style.css",
                       "/tok/img/", "/tok/img", "/tok/missing.html", "/tok/a%00b"] {
            XCTAssertEqual(get(target).status, 404, target)
        }
    }

    func testBrokenPercentEncodingIsABadRequest() {
        XCTAssertEqual(get("/tok/%zz").status, 400)
    }

    func testSymlinkEscapingTheRootOrIntoAHiddenFileIsRefused() throws {
        let manager = FileManager.default
        try manager.createSymbolicLink(at: root.appendingPathComponent("leak.txt"),
                                       withDestinationURL: outside.appendingPathComponent("keys.txt"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("up"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: root.appendingPathComponent("env.txt"),
                                       withDestinationURL: root.appendingPathComponent(".env"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("gitconfig"),
                                       withDestinationURL: root.appendingPathComponent(".git/config"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("repo"), withDestinationURL: root.appendingPathComponent(".git"))
        try manager.createSymbolicLink(at: root.appendingPathComponent("alias.css"),
                                       withDestinationURL: root.appendingPathComponent("style.css"))
        for target in ["/tok/leak.txt", "/tok/up/keys.txt", "/tok/env.txt", "/tok/gitconfig", "/tok/repo/config"] {
            XCTAssertEqual(get(target).status, 404, target)
        }
        XCTAssertEqual(get("/tok/alias.css").status, 200, "a link that stays inside and visible is fine")
    }

    func testARootInsideAHiddenFolderStillServes() throws {
        // A session worktree lives under `<repo>/.claude/worktrees/<slug>`:
        // only the path below the root is checked for hidden components.
        let hidden = root.appendingPathComponent(".claude/worktrees/wt")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "<p>wt</p>".write(to: hidden.appendingPathComponent("deck.html"), atomically: true, encoding: .utf8)
        XCTAssertNotNil(LocalPreviewHTTP.resolve(["deck.html"], under: hidden))
    }

    func testAFileOverTheCapIsRefusedUnread() throws {
        let big = root.appendingPathComponent("huge.html")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(LocalPreviewHTTP.maxFileBytes + 1)) // sparse: nothing written
        try handle.close()
        XCTAssertEqual(get("/tok/huge.html").status, 413)
        let shrink = try FileHandle(forWritingTo: big)
        try shrink.truncate(atOffset: UInt64(LocalPreviewHTTP.maxFileBytes))
        try shrink.close()
        XCTAssertEqual(get("/tok/huge.html", method: "HEAD").status, 200, "exactly the cap is served")
    }

    // MARK: servable folders

    func testAHiddenCodeRootAndAFolderInsideItAreServable() throws {
        // A session worktree: the code root itself is under `.claude/`.
        let worktree = root.appendingPathComponent(".claude/worktrees/wt")
        let slides = worktree.appendingPathComponent("slides")
        try FileManager.default.createDirectory(at: slides, withIntermediateDirectories: true)
        XCTAssertNotNil(LocalPreviewHTTP.servableFolder(worktree, within: worktree))
        XCTAssertNotNil(LocalPreviewHTTP.servableFolder(slides, within: worktree))
        XCTAssertNotNil(LocalPreviewHTTP.servableFolder(root, within: root))
        XCTAssertNotNil(LocalPreviewHTTP.servableFolder(root.appendingPathComponent("img"), within: root))
    }

    func testAHiddenFolderBelowTheCodeRootOrOutsideItIsNot() throws {
        // A home-folder workbench must not serve `~/.ssh` or `~/.aws`.
        let ssh = root.appendingPathComponent(".ssh")
        let nested = root.appendingPathComponent(".aws/sub")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertNil(LocalPreviewHTTP.servableFolder(ssh, within: root))
        XCTAssertNil(LocalPreviewHTTP.servableFolder(nested, within: root))
        XCTAssertNil(LocalPreviewHTTP.servableFolder(root.appendingPathComponent(".git"), within: root))
        XCTAssertNil(LocalPreviewHTTP.servableFolder(outside, within: root), "outside the code root")
        let link = root.appendingPathComponent("keys")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ssh)
        XCTAssertNil(LocalPreviewHTTP.servableFolder(link, within: root), "a symlink into a hidden folder")
    }

    // MARK: registry

    func testRegistryKeepsATokenPerIDAndForgetsOnUnregister() {
        var registry = LocalPreviewRegistry()
        let first = registry.register(id: "folder:/a", folder: root)
        let again = registry.register(id: "folder:/a", folder: outside)
        let other = registry.register(id: "folder:/b", folder: root)
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, other)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(registry.folder(token: first), outside)
        registry.unregister(id: "folder:/a")
        XCTAssertNil(registry.folder(token: first))
        XCTAssertNotNil(registry.folder(token: other))
    }

    func testContentTypes() {
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "HTM"), "text/html; charset=utf-8")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "js"), "text/javascript; charset=utf-8")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "svg"), "image/svg+xml")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "woff2"), "font/woff2")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "bin"), "application/octet-stream")
        XCTAssertEqual(LocalPreviewHTTP.contentType(forExtension: "mp4"), "application/octet-stream", "no Range support, no video")
    }
}
