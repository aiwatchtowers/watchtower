import XCTest
@testable import WatchtowerDesktop

final class MarkdownToHTMLTests: XCTestCase {
    func testHeadersAndParagraph() {
        let html = MarkdownToHTML.convert("# Title\n\n## Sub\n\nHello world")
        XCTAssertEqual(html, "<h1>Title</h1>\n<h2>Sub</h2>\n<p>Hello world</p>")
    }

    func testBoldListItems() {
        let md = "## Decisions\n- **Стойка во Франкфурте:** передать Никите.\n- **Onyx AI** берёт Бодя."
        let html = MarkdownToHTML.convert(md)
        XCTAssertEqual(html, """
        <h2>Decisions</h2>
        <ul><li><strong>Стойка во Франкфурте:</strong> передать Никите.</li>\
        <li><strong>Onyx AI</strong> берёт Бодя.</li></ul>
        """)
    }

    func testNumberedList() {
        let html = MarkdownToHTML.convert("1. first\n2) second")
        XCTAssertEqual(html, "<ol><li>first</li><li>second</li></ol>")
    }

    func testListContinuationLineJoinsPreviousItem() {
        let html = MarkdownToHTML.convert("- item start\ncontinued here\n- next")
        XCTAssertEqual(html, "<ul><li>item start continued here</li><li>next</li></ul>")
    }

    func testInlineCodeItalicAndLink() {
        let html = MarkdownToHTML.convert("use `go test` with *care* — see [docs](https://example.com/a?b=1)")
        XCTAssertEqual(
            html,
            "<p>use <code>go test</code> with <em>care</em> — see <a href=\"https://example.com/a?b=1\">docs</a></p>")
    }

    func testDisallowedLinkSchemeStaysPlainText() {
        let html = MarkdownToHTML.convert("[click](javascript:alert(1))")
        XCTAssertFalse(html.contains("<a "))
        XCTAssertTrue(html.contains("[click](javascript:alert(1))"))
    }

    func testHTMLEscaping() {
        let html = MarkdownToHTML.convert("rollup <= 4 ч & no <b>injection</b>")
        XCTAssertEqual(html, "<p>rollup &lt;= 4 ч &amp; no &lt;b&gt;injection&lt;/b&gt;</p>")
    }

    func testCodeBlockPreservesContentUnformatted() {
        let html = MarkdownToHTML.convert("```\n**not bold** <tag>\nline2\n```")
        XCTAssertEqual(html, "<pre><code>**not bold** &lt;tag&gt;\nline2</code></pre>")
    }

    func testBlockquoteAndDivider() {
        let html = MarkdownToHTML.convert("> quoted text\n\n---")
        XCTAssertEqual(html, "<blockquote>quoted text</blockquote>\n<hr>")
    }

    func testParagraphLineBreaksBecomeBr() {
        let html = MarkdownToHTML.convert("**Date:** 12 августа 2026\n**Участники:** Олег, Вадим")
        XCTAssertEqual(html, "<p><strong>Date:</strong> 12 августа 2026<br><strong>Участники:</strong> Олег, Вадим</p>")
    }

    func testEmptyInput() {
        XCTAssertEqual(MarkdownToHTML.convert(""), "")
    }
}
