import XCTest
@testable import WatchtowerDesktop

/// Pins the MarkdownText block parser and its memoization: the caches must be
/// pure — a warm lookup byte-equal to a fresh parse — and must not drop the
/// inline attributes (bold/links) the renderer depends on.
final class MarkdownTextTests: XCTestCase {
    func testParseBlocksStructure() {
        let md = """
        # Title

        para line1
        line2

        - a
        - b

        1. one
        2. two

        > quoted

        ```
        code here
        ```

        ---
        """
        let blocks = MarkdownText(text: md).blocks()
        XCTAssertEqual(blocks, [
            .header(1, "Title"),
            .paragraph("para line1\nline2"),
            .bulletList(["a", "b"]),
            .numberedList(["one", "two"]),
            .blockquote("quoted"),
            .codeBlock("code here"),
            .divider,
        ])
    }

    func testCachedBlocksEqualFreshParse() {
        let md = "## H\n\ntext **bold**\n\n- item one\n- item two"
        let fresh = MarkdownText(text: md).blocks()
        let warm = MarkdownText(text: md).blocks()
        XCTAssertEqual(fresh, warm)
    }

    func testInlineAttributedKeepsAttributesThroughCache() {
        let source = "a **b** [link](https://example.com)"
        let first = MarkdownText.inlineAttributed(source)
        let second = MarkdownText.inlineAttributed(source)
        XCTAssertEqual(first, second)

        let hasBold = first.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
        }
        XCTAssertTrue(hasBold, "bold must survive the cache")
        let hasLink = first.runs.contains { $0.link != nil }
        XCTAssertTrue(hasLink, "an allowed-scheme link must survive the cache")
    }

    /// A disallowed scheme loses its .link attribute on the cached path too —
    /// the cache stores the already-sanitized string, never the raw parse.
    func testInlineAttributedStripsDisallowedLinksBeforeCaching() {
        let source = "[x](javascript:alert(1))"
        for _ in 0..<2 {
            let attr = MarkdownText.inlineAttributed(source)
            XCTAssertFalse(attr.runs.contains { $0.link != nil })
        }
    }

    /// Unparseable markdown falls back to the plain text, cached the same way.
    func testInlineAttributedFallsBackToPlainText() {
        let attr = MarkdownText.inlineAttributed("just plain text")
        XCTAssertEqual(String(attr.characters), "just plain text")
    }
}
