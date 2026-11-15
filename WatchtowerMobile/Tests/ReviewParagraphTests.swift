import Foundation
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// #1787: the review snapshot reads in the screen's own scroll, one line of
/// the rendered text per paragraph. Every paragraph's `range` is a UTF-16
/// range of `document.text`, because comment anchors are offsets into it.
final class ReviewParagraphTests: XCTestCase {
    /// The demo's review #110, rendered as the form renders it.
    private func demoReview() throws -> PlainTextDocument {
        let ask = try XCTUnwrap(try demoSnapshot(now: Date()).asks.first { $0.id == 110 })
        return PlainTextRendering.render(try XCTUnwrap(ask.docSnapshot))
    }

    /// The plain text `PlainTextRendering` gives for a small plan with each
    /// list marker; heading offsets are looked up in the text.
    private func fixture() -> PlainTextDocument {
        let text = "Plan\n\nIntro text.\n\nSteps\n\n• A first item\n• Second\n\n1. Numbered\n\n☐ Open task\n\n    • Nested\n\nDetail\n\n\u{00A0}\n\n"
        let headings = [("Plan", 1), ("Steps", 2), ("Detail", 3)].map { title, level in
            PlainTextDocument.Heading(offset: (text as NSString).range(of: title).location, level: level, title: title)
        }
        return PlainTextDocument(text: text, headings: headings)
    }

    func testLinesBecomeParagraphsWithHeadingsAndMarkers() {
        let document = fixture()
        let paragraphs = ReviewParagraph.split(document)
        XCTAssertEqual(
            paragraphs.map(\.text), ["Plan", "Intro text.", "Steps", "A first item", "Second", "Numbered", "Open task", "Nested", "Detail"],
            "blank lines and a rule's no-break space are not paragraphs"
        )
        XCTAssertEqual(paragraphs.map(\.headingLevel), [1, nil, 2, nil, nil, nil, nil, nil, 3])
        XCTAssertEqual(paragraphs.map(\.marker), [nil, nil, nil, "• ", "• ", "1. ", "☐ ", "    • ", nil])
        let text = document.text as NSString
        for paragraph in paragraphs {
            XCTAssertEqual(text.substring(with: paragraph.range), paragraph.text, "the range is the text in the document")
            XCTAssertEqual(paragraph.id, paragraph.extent.location)
            XCTAssertEqual(NSMaxRange(paragraph.range), NSMaxRange(paragraph.extent), "the marker is the only part left out")
        }
    }

    func testEdgeDocuments() {
        XCTAssertEqual(ReviewParagraph.split(PlainTextDocument(text: "", headings: [])), [])
        let tail = ReviewParagraph.split(PlainTextDocument(text: "Body\n\nLast", headings: [.init(offset: 6, level: 2, title: "Last")]))
        XCTAssertEqual(tail.map(\.text), ["Body", "Last"], "a last line without a newline")
        XCTAssertEqual(tail.last?.headingLevel, 2)
        XCTAssertNil(ReviewParagraph.listPrefix(of: "Step 2: the Stop hook"))
        XCTAssertEqual(ReviewParagraph.listPrefix(of: "12. Twelfth"), "12. ")
    }

    func testALocationFindsItsParagraph() {
        let paragraphs = ReviewParagraph.split(fixture())
        for (index, paragraph) in paragraphs.enumerated() {
            XCTAssertEqual(ReviewParagraph.index(of: paragraph.range.location, in: paragraphs), index)
            XCTAssertEqual(ReviewParagraph.index(of: paragraph.extent.location, in: paragraphs), index, "the marker is part of the line")
        }
        XCTAssertNil(ReviewParagraph.index(of: 5, in: paragraphs), "a blank line")
        XCTAssertNil(ReviewParagraph.index(of: 10_000, in: paragraphs), "past the text")
    }

    /// #1787 review: the sheet's Add never yields an empty anchor — a
    /// whitespace-only selection quotes the whole paragraph, a selection's
    /// end spaces are trimmed.
    func testTheSheetsQuoteIsNeverBlank() throws {
        let document = try demoReview()
        let paragraph = try XCTUnwrap(ReviewParagraph.split(document).first { $0.text.hasPrefix("Step 2") })
        let text = paragraph.text as NSString
        XCTAssertEqual(paragraph.quoteRange(selection: NSRange(location: 0, length: 0)), paragraph.range, "nothing selected")
        let space = text.range(of: " ")
        XCTAssertEqual(paragraph.quoteRange(selection: space), paragraph.range, "only a space selected")
        XCTAssertNotNil(CommentAnchorBuilder.anchor(selection: paragraph.quoteRange(selection: space), in: document))
        let padded = NSRange(location: text.range(of: " the Stop").location, length: " the Stop ".count)
        let quoted = paragraph.quoteRange(selection: padded)
        XCTAssertEqual((document.text as NSString).substring(with: quoted), "the Stop")
        XCTAssertEqual(paragraph.quoteRange(selection: NSRange(location: 2, length: 10_000)), paragraph.range, "past the text")
    }

    /// A comment on a whole paragraph, or on words picked inside it, anchors
    /// as the same range of the plain text does.
    func testAParagraphAnchorsAsThePlainText() throws {
        let document = try demoReview()
        let paragraph = try XCTUnwrap(ReviewParagraph.split(document).first { $0.text.hasPrefix("Step 2") })
        let whole = try XCTUnwrap(CommentAnchorBuilder.anchor(selection: paragraph.range, in: document))
        XCTAssertEqual(whole.quote, "Step 2: the Stop hook asks the owner first.")
        XCTAssertEqual(whole.heading, "Steps")
        let words = (paragraph.text as NSString).range(of: "the Stop hook")
        let picked = NSRange(location: paragraph.range.location + words.location, length: words.length)
        XCTAssertEqual(
            CommentAnchorBuilder.anchor(selection: picked, in: document),
            CommentAnchorBuilder.anchor(selection: (document.text as NSString).range(of: "the Stop hook"), in: document)
        )
    }
}
