#if os(macOS)
import AppKit
import ChatWire
import WatchtowerChatText
import WatchtowerDesign
import XCTest
@testable import ChatUI

/// Spec 2026-11-24-workchat-polish §2: the agent's text in a highlighting feed gets its refs, hashes, resolved paths
/// and commands in their `SyntaxTint` — the foreground only, never in a link or non-command inline code — and only
/// there.
@MainActor
final class AgentTextHighlightTests: XCTestCase {
    private let markdown = """
    Round 3 of #2188 is ready (67a59755a). Run `make test` or `foo bar`, see [#12](https://example.com) \
    and internal/a.go or docs/missing.md
    """

    private func runText(_ text: String) -> NSAttributedString {
        let segments = MarkdownRunBuilder.segments(MarkdownDocument.parse(text))
        guard case let .textRun(run) = segments.first else {
            XCTFail("one text run expected")
            return NSAttributedString()
        }
        return MarkdownRunText.attributed(run, links: InlineLinkContext(codeLinks: false, navScreens: []))
    }

    private func attributes(of needle: String, in text: NSAttributedString) -> [NSAttributedString.Key: Any] {
        let range = (text.string as NSString).range(of: needle)
        XCTAssertNotEqual(range.location, NSNotFound, needle)
        guard range.location != NSNotFound else { return [:] }
        var effective = NSRange()
        let attributes = text.attributes(at: range.location, effectiveRange: &effective)
        if attributes[.agentHighlight] != nil {
            XCTAssertEqual(effective, range, "the span covers exactly \(needle)")
        }
        return attributes
    }

    private func kind(of needle: String, in text: NSAttributedString) -> AgentTextHighlights.Kind? {
        (attributes(of: needle, in: text)[.agentHighlight] as? AgentTextHighlightBox)?.span.kind
    }

    func testSpansGetTheirTintAndNothingElse() {
        let base = runText(markdown)
        let text = AgentTextHighlightRender.highlighted(base) { $0 == "internal/a.go" }
        XCTAssertEqual(kind(of: "#2188", in: text), .ref(2188))
        XCTAssertEqual(kind(of: "67a59755a", in: text), .hash)
        XCTAssertEqual(kind(of: "make test", in: text), .command)
        XCTAssertEqual(kind(of: "internal/a.go", in: text), .path)
        XCTAssertNil(kind(of: "foo bar", in: text), "inline code that is no command stays plain")
        XCTAssertNil(kind(of: "#12", in: text), "a link is never highlighted")
        XCTAssertNil(kind(of: "docs/missing.md", in: text), "a path that does not resolve stays plain")

        let tints: [(String, NSColor)] = [
            ("#2188", NSColor(SyntaxTint.ref)), ("67a59755a", NSColor(SyntaxTint.hash)),
            ("make test", NSColor(SyntaxTint.command)), ("internal/a.go", NSColor(SyntaxTint.path))
        ]
        for (needle, tint) in tints {
            let attributes = attributes(of: needle, in: text)
            XCTAssertEqual(attributes[.foregroundColor] as? NSColor, tint, needle)
            // D3: colour only — the font (weight) is the base text's, no background, no underline at rest.
            XCTAssertEqual(attributes[.font] as? NSFont, self.attributes(of: needle, in: base)[.font] as? NSFont, needle)
            XCTAssertNil(attributes[.backgroundColor], needle)
            XCTAssertNil(attributes[.underlineStyle], needle)
        }
    }

    func testNothingToColourKeepsTheRunText() {
        let base = runText("Nothing to see here, `foo bar` and docs/missing.md.")
        XCTAssertTrue(AgentTextHighlightRender.highlighted(base) { _ in false } === base)
    }

    func testTheColouredTextIsMemoisedPerResolvedPaths() {
        let base = runText(markdown)
        let first = AgentTextHighlightRender.highlighted(base) { $0 == "internal/a.go" }
        XCTAssertTrue(AgentTextHighlightRender.highlighted(base) { $0 == "internal/a.go" } === first)
        let both = AgentTextHighlightRender.highlighted(base) { _ in true }
        XCTAssertFalse(both === first)
        XCTAssertEqual(kind(of: "docs/missing.md", in: both), .path)
    }

    private func context(role: String, highlights: Bool) -> ChatPartContext {
        ChatPartContext(message: ChatFeed.Message(id: 1, role: role, text: "#1", createdAt: .distantPast),
                        highlightsAgentText: highlights)
    }

    func testOnlyTheAgentsTextInAHighlightingFeed() {
        XCTAssertNotNil(AgentTextHighlighting(context(role: "assistant", highlights: true)))
        XCTAssertNil(AgentTextHighlighting(context(role: "assistant", highlights: false)))
        XCTAssertNil(AgentTextHighlighting(context(role: "user", highlights: true)))
        XCTAssertFalse(ChatFeedContext().highlightsAgentText, "the AI chat and the phone stay plain by default")
    }

    func testAFeedPassesItsFlagToThePartContext() {
        var actions = ChatPartActions()
        var opened: [AgentTextHighlights.Span] = []
        actions.openHighlight = { opened.append($0) }
        actions.resolvesPath = { $0 == "a/b.go" }
        let highlighting = AgentTextHighlighting(ChatPartContext(
            message: ChatFeed.Message(id: 1, role: "assistant", text: "", createdAt: .distantPast),
            actions: actions, highlightsAgentText: true))
        XCTAssertEqual(highlighting?.resolvesPath("a/b.go"), true)
        XCTAssertEqual(highlighting?.resolvesPath("c.go"), false)
        let span = AgentTextHighlights.spans(inPlain: "#7")[0]
        highlighting?.open(span)
        XCTAssertEqual(opened, [span])
    }
}
#endif
