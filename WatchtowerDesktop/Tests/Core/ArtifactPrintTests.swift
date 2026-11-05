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

    func testNothingInTheDocumentPageLoadsOrRuns() {
        let page = ArtifactPrint.documentPage(markdown: """
        <script>alert(1)</script>

        Inline <img src="https://evil.example/p.png"> and <iframe src="https://evil.example"></iframe>

        ![chart](https://evil.example/c.png) ![](https://evil.example/d.png)

        [ok](https://example.com/a?b=1&c=2) [js](javascript:alert(1)) [mail](mailto:a@example.com)

        &lt;script&gt;decoded&lt;/script&gt;
        """, title: "<b>\"T\"</b>")
        for forbidden in ["<script", "<img", "<iframe", "url(", "javascript:alert(1)\""] {
            XCTAssertFalse(page.contains(forbidden), forbidden)
        }
        XCTAssertTrue(page.contains("<title>&lt;b&gt;&quot;T&quot;&lt;/b&gt;</title>"))
        XCTAssertTrue(page.contains("<a href=\"https://example.com/a?b=1&amp;c=2\">ok</a>"))
        XCTAssertTrue(page.contains("<a href=\"mailto:a@example.com\">mail</a>"))
        XCTAssertTrue(page.contains("js"), "a non-web link keeps its text")
        XCTAssertFalse(page.contains("href=\"javascript"))
        XCTAssertTrue(page.contains("<a href=\"https://evil.example/c.png\">chart</a>"), "an image is a link, never loaded")
        XCTAssertTrue(page.contains("&lt;script&gt;"))
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
