import XCTest
@testable import WatchtowerCore

/// The live loopback server: bound to 127.0.0.1, serving a folder by token.
final class LocalPreviewServerTests: XCTestCase {
    private var folder: URL!
    private let session = URLSession(configuration: .ephemeral)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("local-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ text: String, _ name: String) throws {
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testServesARegisteredFolderOnLoopbackAndForgetsItOnUnregister() async throws {
        try write("<p>deck</p>", "index.html")
        let server = LocalPreviewServer()
        defer { server.stop() }
        let url = try await server.url(forFile: "index.html", inFolder: folder, within: folder, id: "folder:a")
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertEqual(url.lastPathComponent, "index.html")

        let (data, response) = try await session.data(from: url)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "<p>deck</p>")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Security-Policy"), LocalPreviewHTTP.contentSecurityPolicy)

        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        let (_, postResponse) = try await session.data(for: post)
        XCTAssertEqual((postResponse as? HTTPURLResponse)?.statusCode, 405)

        let again = try await server.url(forFile: "index.html", inFolder: folder, within: folder, id: "folder:a")
        XCTAssertEqual(again, url, "the same id keeps its URL")

        server.unregister(id: "folder:a")
        let (_, gone) = try await session.data(from: url)
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 404)
    }

    func testAHiddenFolderBelowTheCodeRootIsNeverRegistered() async throws {
        let ssh = folder.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try "<p>key</p>".write(to: ssh.appendingPathComponent("id.html"), atomically: true, encoding: .utf8)
        let server = LocalPreviewServer()
        defer { server.stop() }
        do {
            _ = try await server.url(forFile: "id.html", inFolder: ssh, within: folder, id: "folder:ssh")
            XCTFail("a hidden folder below the workbench must be refused")
        } catch LocalPreviewServer.Failure.refused {
            // expected
        }
        let worktree = folder.appendingPathComponent(".claude/worktrees/wt")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "<p>wt</p>".write(to: worktree.appendingPathComponent("deck.html"), atomically: true, encoding: .utf8)
        let url = try await server.url(forFile: "deck.html", inFolder: worktree, within: worktree, id: "folder:wt")
        let (data, _) = try await session.data(from: url)
        XCTAssertEqual(String(bytes: data, encoding: .utf8), "<p>wt</p>", "a session worktree root may be hidden")
    }

    func testFileNamesRoundTripIncludingALiteralPercent() async throws {
        try write("<h1>space</h1>", "my deck.html")
        try write("<h1>percent</h1>", "report%20final.html")
        try write("<h1>plain space</h1>", "report final.html")
        let server = LocalPreviewServer()
        defer { server.stop() }

        let spaced = try await server.url(forFile: "my deck.html", inFolder: folder, within: folder, id: "folder:b")
        XCTAssertTrue(spaced.absoluteString.hasSuffix("/my%20deck.html"))
        let (spacedData, _) = try await session.data(from: spaced)
        XCTAssertEqual(String(bytes: spacedData, encoding: .utf8), "<h1>space</h1>")

        let percent = try await server.url(forFile: "report%20final.html", inFolder: folder, within: folder, id: "folder:b")
        XCTAssertTrue(percent.absoluteString.hasSuffix("/report%2520final.html"))
        let (percentData, _) = try await session.data(from: percent)
        XCTAssertEqual(String(bytes: percentData, encoding: .utf8), "<h1>percent</h1>", "not the file named with a space")
    }

    /// The send is not under the header timeout, and a big reply goes out
    /// whole while another request is answered.
    func testABigFileArrivesWholeAndDoesNotBlockAnotherRequest() async throws {
        let big = Data(repeating: 0x61, count: 12 * 1024 * 1024)
        try big.write(to: folder.appendingPathComponent("big.txt"))
        try write("small", "small.txt")
        let server = LocalPreviewServer()
        defer { server.stop() }
        let bigURL = try await server.url(forFile: "big.txt", inFolder: folder, within: folder, id: "folder:c")
        let smallURL = try await server.url(forFile: "small.txt", inFolder: folder, within: folder, id: "folder:c")
        async let bigFetch = session.data(from: bigURL)
        async let smallFetch = session.data(from: smallURL)
        let (bigData, _) = try await bigFetch
        let (smallData, _) = try await smallFetch
        XCTAssertEqual(bigData.count, big.count)
        XCTAssertEqual(String(bytes: smallData, encoding: .utf8), "small")
    }
}
