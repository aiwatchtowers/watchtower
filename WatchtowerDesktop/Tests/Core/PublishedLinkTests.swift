import XCTest
@testable import WatchtowerCore

/// #737: a `claude_ai_published` source becomes a "Published on claude.ai"
/// card only for an https claude.ai page; its actions only open or copy.
final class PublishedLinkTests: XCTestCase {
    private func published(_ url: String?, title: String = "Quarterly plan") -> ChatSource {
        ChatSource(kind: PublishedLink.sourceKind, title: title, url: url, ref: url ?? "")
    }

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

    func testPublishedLinkOnlyForClaudeAIHTTPS() {
        XCTAssertEqual(PublishedLink.links(from: [published("https://claude.ai/artifact/abc")]).count, 1)
        XCTAssertEqual(PublishedLink.links(from: [published("HTTPS://Claude.AI/artifact/abc")]).count, 1,
                       "scheme and host compare case-insensitively")
        let refused: [String?] = [
            nil,
            "",
            "http://claude.ai/artifact/abc",
            "https://example.com/artifact/abc",
            "https://claude.ai.example.com/artifact/abc",
            "https://www.claude.ai/artifact/abc",
            "https://claude.ai./artifact/abc",
            "https://claude%2Eai/artifact/abc",
            "https://claude.ai@example.com/artifact/abc", // leak-check:allow (userinfo bypass probes)
            "https://user@claude.ai/artifact/abc", // leak-check:allow (userinfo bypass probes)
            "https://user:pw@claude.ai/artifact/abc", // leak-check:allow (userinfo bypass probes)
            "https://claude.ai:8443/artifact/abc",
            "https://claude.ai",
            "https://claude.ai/",
            "javascript:alert(1)",
            "file:///Users/someone/page.html",
            "claude.ai/artifact/abc",
            "/artifact/abc"
        ]
        for url in refused {
            XCTAssertEqual(PublishedLink.links(from: [published(url)]), [], url ?? "nil")
        }
    }

    func testOnlyThePublishedKindBecomesACard() {
        let sources = [
            ChatSource(kind: "web", title: "w", url: "https://claude.ai/artifact/abc", ref: "r"),
            ChatSource(kind: "document", title: "d", url: "https://claude.ai/artifact/def", ref: "r")
        ]
        XCTAssertEqual(PublishedLink.links(from: sources), [])
    }

    func testLinksKeepOrderAndDedupeByURL() {
        let links = PublishedLink.links(from: [
            published("https://claude.ai/artifact/b", title: "B"),
            published("https://claude.ai/artifact/a", title: "A"),
            published("https://claude.ai/artifact/b", title: "B v2")
        ])
        XCTAssertEqual(links.map(\.title), ["B", "A"])
    }

    func testDedupeIgnoresSchemeAndHostCase() {
        let links = PublishedLink.links(from: [
            published("https://claude.ai/artifact/x", title: "X"),
            published("HTTPS://Claude.AI/artifact/x", title: "X again"),
            published("https://claude.ai/artifact/X", title: "Other page")
        ])
        XCTAssertEqual(links.map(\.title), ["X", "Other page"])
    }

    func testEmptyTitleFallsBackToTheURL() {
        let links = PublishedLink.links(from: [published("https://claude.ai/artifact/abc", title: "  ")])
        XCTAssertEqual(links.map(\.title), ["https://claude.ai/artifact/abc"])
    }

    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    func testPublishedLinkActionsOnlyOpenOrCopy() throws {
        let link = try XCTUnwrap(PublishedLink.links(from: [published("https://claude.ai/artifact/abc")]).first)
        XCTAssertEqual(link.actions, [.open(link.url), .copy("https://claude.ai/artifact/abc")])
        for action in link.actions {
            // Exhaustive on purpose: a new case fails to compile here.
            switch action {
            case .open(let url): XCTAssertTrue(PublishedLink.permits(url))
            case .copy(let text): XCTAssertEqual(text, link.url.absoluteString)
            }
        }
    }
}
