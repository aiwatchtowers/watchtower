import XCTest
@testable import WatchtowerCore

/// The live loopback server: bound to 127.0.0.1, serving a page by token.
final class LocalPreviewServerTests: XCTestCase {
    func testServesARegisteredPageOnLoopbackAndForgetsItOnUnregister() async throws {
        let server = LocalPreviewServer()
        defer { server.stop() }
        let url = try await server.url(for: .page("<p>deck</p>"), id: "chat:1:deck")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.lastPathComponent, "index.html")

        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "<p>deck</p>")

        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        let (_, postResponse) = try await session.data(for: post)
        XCTAssertEqual((postResponse as? HTTPURLResponse)?.statusCode, 405)

        let again = try await server.url(for: .page("<p>v2</p>"), id: "chat:1:deck")
        XCTAssertEqual(again, url, "the same id keeps its URL")
        let (v2, _) = try await session.data(from: url)
        XCTAssertEqual(String(bytes: v2, encoding: .utf8), "<p>v2</p>")

        server.unregister(id: "chat:1:deck")
        let (_, gone) = try await session.data(from: url)
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404)
    }

    func testAFileURLKeepsItsFolderRelativePath() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "<h1>A B</h1>".write(to: folder.appendingPathComponent("my deck.html"), atomically: true, encoding: .utf8)
        let server = LocalPreviewServer()
        defer { server.stop() }
        let url = try await server.url(for: .folder(folder), id: "folder:\(folder.path)", file: "my deck.html")
        XCTAssertTrue(url.absoluteString.hasSuffix("/my%20deck.html"))
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: url)
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "<h1>A B</h1>")
    }
}
