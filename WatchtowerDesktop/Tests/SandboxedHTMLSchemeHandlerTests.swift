import WebKit
import XCTest
@testable import WatchtowerDesktop

/// The in-app preview's file handler (#563), driven with a recording task:
/// ranges across chunks, refusals, stale tokens and a stopped task.
@MainActor
final class SandboxedHTMLSchemeHandlerTests: XCTestCase {
    private var folder: URL!
    private let webView = WKWebView()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testALargeFileAndARangeAcrossChunksArriveWhole() async throws {
        let body = Data((0..<(SandboxedHTMLSchemeHandler.chunkBytes * 3 + 17)).map { UInt8($0 % 251) })
        try body.write(to: folder.appendingPathComponent("big.bin"))
        let handler = SandboxedHTMLSchemeHandler()
        let token = handler.serve(folder)

        let whole = try await run(handler, "wtpreview://\(token)/big.bin")
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.data, body)

        let start = SandboxedHTMLSchemeHandler.chunkBytes - 5
        let end = SandboxedHTMLSchemeHandler.chunkBytes * 2 + 9
        let ranged = try await run(handler, "wtpreview://\(token)/big.bin", range: "bytes=\(start)-\(end)")
        XCTAssertEqual(ranged.status, 206)
        XCTAssertEqual(ranged.headers["Content-Range"], "bytes \(start)-\(end)/\(body.count)")
        XCTAssertEqual(ranged.data, body.subdata(in: start..<(end + 1)))

        let past = try await run(handler, "wtpreview://\(token)/big.bin", range: "bytes=\(body.count)-")
        XCTAssertEqual(past.status, 416)
    }

    func testNoFolderAStaleTokenOrAHiddenFileGetsNothing() async throws {
        try "<p>a</p>".write(to: folder.appendingPathComponent("a.html"), atomically: true, encoding: .utf8)
        try "x".write(to: folder.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let handler = SandboxedHTMLSchemeHandler()
        let none = handler.serve(nil)
        let nothing = try await run(handler, "wtpreview://\(none)/a.html")
        XCTAssertTrue(nothing.failed, "an in-memory page serves nothing")
        let old = handler.serve(folder)
        let served = try await run(handler, "wtpreview://\(old)/a.html")
        XCTAssertEqual(served.status, 200)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("scheme-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let new = handler.serve(other)
        XCTAssertNotEqual(old, new)
        let late = try await run(handler, "wtpreview://\(old)/a.html")
        XCTAssertTrue(late.failed, "a late request of the earlier page")
        let hidden = try await run(handler, "wtpreview://\(handler.serve(folder))/.env")
        XCTAssertEqual(hidden.status, 404)
    }

    func testAStoppedTaskGetsNothingMore() async throws {
        try Data(count: SandboxedHTMLSchemeHandler.chunkBytes * 4).write(to: folder.appendingPathComponent("big.bin"))
        let handler = SandboxedHTMLSchemeHandler()
        let token = handler.serve(folder)
        // swiftlint:disable:next force_unwrapping
        let task = RecordingTask(URLRequest(url: URL(string: "wtpreview://\(token)/big.bin")!))
        handler.webView(webView, start: task)
        handler.webView(webView, stop: task)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(task.status)
        XCTAssertTrue(task.data.isEmpty)
        XCTAssertFalse(task.finished)
    }

    // MARK: helpers

    private func run(_ handler: SandboxedHTMLSchemeHandler, _ raw: String, range: String? = nil) async throws -> RecordingTask {
        // swiftlint:disable:next force_unwrapping
        var request = URLRequest(url: URL(string: raw)!)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let task = RecordingTask(request)
        handler.webView(webView, start: task)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !task.finished, !task.failed, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return task
    }
}

/// A scheme task that records what the handler hands it.
private final class RecordingTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var status: Int?
    var headers: [String: String] = [:]
    var data = Data()
    var finished = false
    var failed = false

    init(_ request: URLRequest) { self.request = request }

    func didReceive(_ response: URLResponse) {
        let http = response as? HTTPURLResponse
        status = http?.statusCode
        headers = (http?.allHeaderFields as? [String: String]) ?? [:]
    }

    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: any Error) { failed = true }
}
