import XCTest
@testable import WatchtowerCore
import WatchtowerChatText

/// #737: the Go golden's published source, parsed by Core's `ChatEvent`, becomes a
/// "Published on claude.ai" card (the rest of `PublishedLink` is tested in WatchtowerChatText).
final class PublishedLinkGoldenTests: XCTestCase {
    /// Go's own golden (`internal/chat/testdata/events_v2_published_source.jsonl`,
    /// spec §3.1), read in place so a Go shape change breaks this suite too.
    func testGoldenPublishedSourceBecomesALinkCard() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/chat/testdata/events_v2_published_source.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)
        guard case .toolEnd(let end) = ChatEvent.parse(lines[0]) else {
            return XCTFail("the golden must parse as a tool_end")
        }
        XCTAssertEqual(end.sources.map(\.kind), ["claude_ai_published"])
        let links = PublishedLink.links(from: end.sources)
        XCTAssertEqual(links.map(\.title), ["Quarterly plan"])
        XCTAssertEqual(links.map(\.url.absoluteString), ["https://claude.ai/artifact/PrbbeQQQQQQQQQQQQQQQQQ"])
    }
}
