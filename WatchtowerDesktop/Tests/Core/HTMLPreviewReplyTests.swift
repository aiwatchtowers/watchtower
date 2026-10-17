import XCTest
@testable import WatchtowerCore

/// The in-app preview handler's replies (#563).
final class HTMLPreviewReplyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("preview-reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "<h1>deck</h1>".write(to: folder.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try Data(count: 10).write(to: folder.appendingPathComponent("clip.mp4"))
        try "TOKEN=x".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func reply(_ path: String, range: String? = nil) -> HTMLPreviewReply {
        // swiftlint:disable:next force_unwrapping
        HTMLPreviewReply.reply(for: URL(string: "wtpreview://0a1b/" + path)!, folder: folder, range: range)
    }

    func testAFileGetsTheInAppPolicyAndATextCharset() {
        let page = reply("index.html")
        XCTAssertEqual(page.status, 200)
        guard case let .file(file, _, headers, range) = page else { return XCTFail("\(page)") }
        XCTAssertEqual(file.lastPathComponent, "index.html")
        XCTAssertEqual(range, 0..<13)
        XCTAssertEqual(headers["Content-Type"], "text/html; charset=utf-8")
        XCTAssertEqual(headers["Content-Length"], "13")
        XCTAssertEqual(headers["X-Content-Type-Options"], "nosniff")
        XCTAssertEqual(headers["Cache-Control"], "no-store")
        XCTAssertEqual(headers["Content-Security-Policy"], HTMLPreviewPolicy.inAppContentSecurityPolicy)
        XCTAssertEqual(reply("clip.mp4").headers["Content-Type"], "video/mp4", "media plays in the app: ranges are answered")
    }

    func testTheInAppPolicyForbidsFetchAndWorkersButShowsOwnFrames() {
        let policy = HTMLPreviewPolicy.inAppContentSecurityPolicy
        for directive in ["connect-src 'none'", "worker-src 'none'", "object-src 'none'", "form-action 'none'", "base-uri 'none'",
                          "frame-src 'self'", "child-src 'self'", "default-src 'self'",
                          "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://"] {
            XCTAssertTrue(policy.contains(directive), directive)
        }
        XCTAssertFalse(policy.contains("https:;"))
        XCTAssertFalse(LocalPreviewHTTP.contentSecurityPolicy.contains("unsafe-eval"), "the browser keeps it off")
        XCTAssertTrue(LocalPreviewHTTP.contentSecurityPolicy.hasSuffix(HTMLPreviewPolicy.sourcePolicy(frames: "'none'")),
                      "the browser shares the same source directives")
    }

    func testRangesAreAnsweredWith206Or416() {
        let partial = reply("index.html", range: "bytes=4-7")
        XCTAssertEqual(partial.status, 206)
        guard case let .file(_, _, headers, range) = partial else { return XCTFail("\(partial)") }
        XCTAssertEqual(range, 4..<8)
        XCTAssertEqual(headers["Content-Range"], "bytes 4-7/13")
        XCTAssertEqual(headers["Content-Length"], "4")
        let past = reply("index.html", range: "bytes=13-")
        XCTAssertEqual(past.status, 416)
        XCTAssertEqual(past.headers["Content-Range"], "bytes */13")
        XCTAssertEqual(reply("index.html", range: "bytes=0-1,4-5").status, 200, "several ranges: the whole file")
    }

    func testHiddenMissingAndOversizedFilesAreRefused() throws {
        XCTAssertEqual(reply(".env").status, 404)
        XCTAssertEqual(reply("missing.html").status, 404)
        let big = folder.appendingPathComponent("huge.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(LocalPreviewHTTP.maxFileBytes + 1)) // sparse: nothing written
        try handle.close()
        let refused = reply("huge.bin")
        XCTAssertEqual(refused.status, 413)
        guard case let .refusal(_, headers, body) = refused else { return XCTFail("\(refused)") }
        XCTAssertEqual(String(bytes: body, encoding: .utf8), "413 Content Too Large\n")
        XCTAssertEqual(headers["Content-Security-Policy"], HTMLPreviewPolicy.inAppContentSecurityPolicy)
    }
}
