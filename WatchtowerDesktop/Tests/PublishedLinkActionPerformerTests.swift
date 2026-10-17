import XCTest
import AppKit
import WatchtowerCore
@testable import WatchtowerDesktop

/// #737 CHAT-05: a published-link action only opens a claude.ai page or
/// copies the link; an `.open` of any other URL does nothing.
@MainActor
final class PublishedLinkActionPerformerTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("wt-published-\(UUID().uuidString)"))
    }

    func testOpenPermittedPage() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let url = try XCTUnwrap(URL(string: "https://claude.ai/artifact/abc"))
        var opened: [URL] = []
        let done = PublishedLinkActionPerformer.perform(.open(url), pasteboard: board) {
            opened.append($0)
            return true
        }
        XCTAssertTrue(done)
        XCTAssertEqual(opened, [url])
        XCTAssertNil(board.string(forType: .string), "open never copies")
    }

    func testOpenRefusesAnyOtherURL() throws {
        for raw in ["https://example.com/x", "http://claude.ai/artifact/abc", "file:///tmp/x.html"] {
            let url = try XCTUnwrap(URL(string: raw))
            let done = PublishedLinkActionPerformer.perform(.open(url), pasteboard: pasteboard()) { _ in
                XCTFail("\(raw) must not open")
                return true
            }
            XCTAssertFalse(done, raw)
        }
    }

    func testOpenReportsAFailedOpen() throws {
        let url = try XCTUnwrap(URL(string: "https://claude.ai/artifact/abc"))
        XCTAssertFalse(PublishedLinkActionPerformer.perform(.open(url), pasteboard: pasteboard()) { _ in false })
    }

    func testCopyWritesTheLinkAndOpensNothing() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        let done = PublishedLinkActionPerformer.perform(.copy("https://claude.ai/artifact/abc"), pasteboard: board) { _ in
            XCTFail("copy never opens")
            return true
        }
        XCTAssertTrue(done)
        XCTAssertEqual(board.string(forType: .string), "https://claude.ai/artifact/abc")
    }
}
