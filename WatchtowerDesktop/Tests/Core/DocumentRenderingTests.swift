import XCTest
@testable import WatchtowerCore

final class DocumentRenderingTests: XCTestCase {
    func testHeadingsParagraphsAndSoftBreaksFlattenToPlainText() {
        let doc = DocumentRendering.render("# Title\n\nSome *soft*\nwrapped text.\n\n## Errors\n\nRetry `twice`.")
        XCTAssertEqual(doc.text, "Title\n\nSome soft wrapped text.\n\nErrors\n\nRetry twice.\n\n")
        let errors = (doc.text as NSString).range(of: "Errors").location
        XCTAssertEqual(doc.headings, [
            DocumentHeading(offset: 0, level: 1, title: "Title"),
            DocumentHeading(offset: errors, level: 2, title: "Errors")
        ])
        XCTAssertEqual(doc.headingOffsets.map(\.title), ["Title", "Errors"])
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: 0, length: 5, style: .heading(1))))
        let soft = (doc.text as NSString).range(of: "soft")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: soft.location, length: soft.length, style: .emphasis)))
        let twice = (doc.text as NSString).range(of: "twice")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: twice.location, length: twice.length, style: .code)))
    }

    func testListsGetMarkersAndTaskBoxes() {
        let doc = DocumentRendering.render("- one\n- [x] two\n- [ ] three\n\n1. first\n2. second")
        XCTAssertEqual(doc.text, "• one\n☑ two\n☐ three\n\n1. first\n2. second\n\n")
    }

    func testFencedCodeIsVerbatimAndStyled() {
        let doc = DocumentRendering.render("Intro.\n\n```go\nx := 1\ny := 2\n```")
        XCTAssertEqual(doc.text, "Intro.\n\nx := 1\ny := 2\n\n")
        let code = (doc.text as NSString).range(of: "x := 1\ny := 2")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: code.location, length: code.length, style: .codeBlock)))
    }

    func testLinkRunCarriesItsDestination() {
        let doc = DocumentRendering.render("See [the spec](docs/spec.md).")
        let link = (doc.text as NSString).range(of: "the spec")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: link.location, length: link.length, style: .link("docs/spec.md"))))
    }

    /// The anchors live on this text, so the same markdown must always render
    /// the same text (a re-anchor on an unchanged file finds every quote).
    func testRenderingIsDeterministicAndAnchorsRoundTrip() throws {
        let markdown = "# Plan\n\n## Task 1\n\nWrite the migration.\n\n## Task 2\n\nWrite the migration tests."
        let first = DocumentRendering.render(markdown)
        XCTAssertEqual(first, DocumentRendering.render(markdown))
        let range = try XCTUnwrap(first.text.range(of: "Write the migration."))
        let anchor = CommentAnchor.make(text: first.text, range: range, headings: first.headingOffsets)
        XCTAssertEqual(anchor.heading, "Task 1")
        XCTAssertEqual(anchor.locate(in: DocumentRendering.render(markdown).text), range)
    }
}
