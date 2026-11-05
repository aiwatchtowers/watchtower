import XCTest
@testable import WatchtowerCore

final class ArtifactPrintTests: XCTestCase {
    private func draft(_ kind: String, _ content: String, complete: Bool = true, title: String = "Q3 plan") -> ArtifactDraft {
        ArtifactDraft(key: "k", kind: kind, title: title, meta: [:], content: content, isComplete: complete)
    }

    func testOnlyDocumentAndHTMLOfferPrintAndOnlyDocumentOffersWord() {
        for kind in ArtifactParser.knownKinds {
            let item = draft(kind, "x")
            XCTAssertEqual(ArtifactPrint.offersPrint(item), kind == "document" || kind == "html", kind)
            XCTAssertEqual(ArtifactPrint.offersWord(item), kind == "document", kind)
        }
    }

    func testStreamingOrEmptyCannotPrintOrExport() {
        XCTAssertFalse(ArtifactPrint.canPrint(draft("html", "<p>half", complete: false)), "html still streaming")
        XCTAssertFalse(ArtifactPrint.canPrint(draft("document", "# Title", complete: false)))
        XCTAssertFalse(ArtifactPrint.canExportWord(draft("document", "# Title", complete: false)))
        XCTAssertFalse(ArtifactPrint.canPrint(draft("document", "  \n\t")), "empty document")
        XCTAssertFalse(ArtifactPrint.canExportWord(draft("document", "")))
        XCTAssertFalse(ArtifactPrint.canPrint(draft("html", "")))
        XCTAssertNil(ArtifactPrint.printPage(for: draft("html", "<p>half", complete: false)))
        XCTAssertNil(ArtifactPrint.printPage(for: draft("table", "a,b")))
        XCTAssertTrue(ArtifactPrint.canPrint(draft("html", "<p>hi</p>")))
        XCTAssertTrue(ArtifactPrint.canExportWord(draft("document", "hi")))
    }

    func testHTMLPrintsItsOwnPage() {
        XCTAssertEqual(ArtifactPrint.printPage(for: draft("html", "<h1>Deck</h1>")), "<h1>Deck</h1>")
    }

    func testDocumentPageRendersMarkdown() throws {
        let page = try XCTUnwrap(ArtifactPrint.printPage(for: draft("document", """
        # Plan

        Some **bold**, *em*, ~~gone~~ and `code`.

        - [x] done
        - open

        3. third
        4. fourth

        > quoted

        | Name | Count |
        |:-----|------:|
        | a    | 1     |

        ```swift
        let x = a < b
        ```

        ---
        """)))
        XCTAssertTrue(page.hasPrefix("<!doctype html>"))
        XCTAssertTrue(page.contains("<title>Q3 plan</title>"))
        XCTAssertTrue(page.contains("<h1>Plan</h1>"))
        XCTAssertTrue(page.contains("<strong>bold</strong>"))
        XCTAssertTrue(page.contains("<em>em</em>"))
        XCTAssertTrue(page.contains("<s>gone</s>"))
        XCTAssertTrue(page.contains("<code>code</code>"))
        XCTAssertTrue(page.contains("<li>☑ done</li>"))
        XCTAssertTrue(page.contains("<li>open</li>"))
        XCTAssertTrue(page.contains("<ol start=\"3\">"))
        XCTAssertTrue(page.contains("<blockquote><p>quoted</p></blockquote>"))
        XCTAssertTrue(page.contains("<th>Name</th><th style=\"text-align:right\">Count</th>"))
        XCTAssertTrue(page.contains("<td>a</td>"))
        XCTAssertTrue(page.contains("<pre><code>let x = a &lt; b</code></pre>"))
        XCTAssertTrue(page.contains("<hr>"))
    }

    /// Every tag the page has is on an allow-list of inert tags, every
    /// attribute is one the renderer writes, and every link is http(s) or
    /// mailto — whatever the markdown smuggles in.
    func testNothingInTheDocumentPageLoadsOrRuns() throws {
        let page = ArtifactPrint.documentPage(markdown: """
        <script>alert(1)</script>

        Inline <img src="https://evil.example/p.png"> and <iframe src="https://evil.example"></iframe>

        <svg onload=alert(1)><link rel=stylesheet href=https://evil.example/s.css><object data=https://evil.example/o></object>

        ![chart](https://evil.example/c.png) ![](https://evil.example/d.png)

        [ok](https://example.com/a?b=1&c=2) [js](javascript:alert(1)) [mail](mailto:a@example.com)

        [data](data:text/html;base64,PHNjcmlwdD5hbGVydCgxKTwvc2NyaXB0Pg==) [upper](HTTPS://example.com/up)

        [quote](https://example.com/"onclick="alert(1))

        &lt;script&gt;decoded&lt;/script&gt;

        # H1

        ###### H6

        Line one\\
        line two

        - item

        1. one

        > quote

        | a | b |
        |---|:-:|
        | 1 | 2 |

        ```
        code
        ```

        ***bold em*** ~~struck~~ `inline`

        ---
        """, title: "<b>\"T\"</b>")

        try assertInert(page)
        XCTAssertFalse(page.contains("url("))
        XCTAssertTrue(page.contains("<title>&lt;b&gt;&quot;T&quot;&lt;/b&gt;</title>"))
        XCTAssertTrue(page.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">ok</a>"))
        XCTAssertTrue(page.contains("<a href=\"mailto:a@example.com\">mail</a>"))
        XCTAssertTrue(page.contains("js"), "a non-web link keeps its text")
        XCTAssertTrue(page.contains("data"), "a data: link keeps its text")
        XCTAssertFalse(page.contains("href=\"data:"))
        XCTAssertTrue(page.contains("<a href=\"HTTPS://example.com/up\">upper</a>"), "an upper-case scheme is still a web link")
        XCTAssertFalse(page.contains("\"onclick="), "a quote in a link destination never closes the href")
        XCTAssertTrue(page.contains("<a href=\"https://evil.example/c.png\">chart</a>"), "an image is a link, never loaded")
        XCTAssertTrue(
            page.contains("<a href=\"https://evil.example/d.png\">https://evil.example/d.png</a>"),
            "an image without alt text is a link showing its address"
        )
        XCTAssertTrue(page.contains("&lt;script&gt;"))
        XCTAssertTrue(page.contains("&lt;svg onload=alert(1)&gt;"), "raw HTML is text")
    }

    /// Every tag is on an allow-list of inert tags, every attribute is one
    /// the renderer writes, and every href is http(s) or mailto.
    private func assertInert(_ page: String) throws {
        let allowedTags: Set<String> = [
            "html", "head", "meta", "title", "style", "body", "h1", "h2", "h3", "h4", "h5", "h6", "p", "pre", "code",
            "ul", "ol", "li", "blockquote", "table", "thead", "tbody", "tr", "th", "td", "hr", "br", "em", "strong", "s", "a"
        ]
        let allowedAttributes: Set<String> = ["charset", "href", "start", "style"]
        let tagPattern = try NSRegularExpression(pattern: "<(/?)([^\\s>/]+)([^>]*)>")
        let attributePattern = try NSRegularExpression(pattern: "\\s([A-Za-z-]+)=\"([^\"]*)\"")
        let whole = NSRange(page.startIndex..., in: page)
        var hrefs: [String] = []
        for match in tagPattern.matches(in: page, range: whole) {
            let name = (page as NSString).substring(with: match.range(at: 2)).lowercased()
            if name == "!doctype" { continue }
            XCTAssertTrue(allowedTags.contains(name), "tag <\(name)>")
            let attributes = (page as NSString).substring(with: match.range(at: 3))
            let found = attributePattern.matches(in: attributes, range: NSRange(attributes.startIndex..., in: attributes))
            for attribute in found {
                let attributeName = (attributes as NSString).substring(with: attribute.range(at: 1))
                XCTAssertTrue(allowedAttributes.contains(attributeName), "attribute \(attributeName) on <\(name)>")
                if attributeName == "href" { hrefs.append((attributes as NSString).substring(with: attribute.range(at: 2))) }
            }
            let rest = attributePattern.stringByReplacingMatches(
                in: attributes, range: NSRange(attributes.startIndex..., in: attributes), withTemplate: ""
            )
            XCTAssertEqual(rest.trimmingCharacters(in: .whitespaces), "", "nothing but quoted attributes on <\(name)>")
        }
        XCTAssertFalse(hrefs.isEmpty)
        for href in hrefs {
            let lower = href.lowercased()
            XCTAssertTrue(["http:", "https:", "mailto:"].contains { lower.hasPrefix($0) }, "href \(href)")
        }
    }

    func testEmptyDocumentPageIsAValidPage() {
        let page = ArtifactPrint.documentPage(markdown: "", title: "")
        XCTAssertTrue(page.contains("<body>"))
        XCTAssertTrue(page.contains("</body></html>"))
    }

    func testWordFileName() {
        XCTAssertEqual(ArtifactPrint.wordFileName(for: draft("document", "x", title: "Q3 plan: draft")), "q3-plan-draft.docx")
    }
}
