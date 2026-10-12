import UIKit
import WatchtowerKit
import XCTest
@testable import WatchtowerMobile

/// Bug 7 (design pass spec §3): the review snapshot reads as a document.
/// The styled string is exactly `document.text`, because comment anchors are
/// UTF-16 offsets into it; only attributes change.
final class ReviewDocumentStylerTests: XCTestCase {
    private let traits = UITraitCollection(preferredContentSizeCategory: .large)

    /// The demo's review #110, rendered as the form renders it.
    private func demoReview() throws -> PlainTextDocument {
        let ask = try XCTUnwrap(try demoSnapshot(now: Date()).asks.first { $0.id == 110 })
        return PlainTextRendering.render(try XCTUnwrap(ask.docSnapshot))
    }

    /// The plain text `PlainTextRendering` gives for a small plan with each
    /// list marker; heading offsets are looked up in the text.
    private func fixture() -> PlainTextDocument {
        let text = "Plan\n\nIntro text.\n\nSteps\n\n• A first item long enough to wrap onto a second line on a phone\n"
            + "• Second\n\n1. Numbered\n\n☐ Open task\n\nDetail\n\n"
        let headings = [("Plan", 1), ("Steps", 2), ("Detail", 3)].map { title, level in
            PlainTextDocument.Heading(offset: (text as NSString).range(of: title).location, level: level, title: title)
        }
        return PlainTextDocument(text: text, headings: headings)
    }

    private func font(_ styled: NSAttributedString, at offset: Int) -> UIFont? {
        styled.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
    }

    private func headIndent(_ styled: NSAttributedString, at offset: Int) -> CGFloat {
        (styled.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1
    }

    private func width(_ prefix: String) -> CGFloat {
        (prefix as NSString).size(withAttributes: [.font: ReviewDocumentStyler.bodyFont(traits: traits)]).width
    }

    func testTheStringIsExactlyTheDocumentsText() throws {
        for document in [try demoReview(), fixture()] {
            XCTAssertEqual(ReviewDocumentStyler.attributed(document, traits: traits).string, document.text)
        }
    }

    func testEveryHeadingLineCarriesItsLevelsFont() throws {
        for document in [try demoReview(), fixture()] {
            let styled = ReviewDocumentStyler.attributed(document, traits: traits)
            XCTAssertFalse(document.headings.isEmpty)
            for heading in document.headings {
                let expected = ReviewDocumentStyler.headingFont(level: heading.level, traits: traits)
                XCTAssertEqual(font(styled, at: heading.offset), expected, heading.title)
                XCTAssertEqual(font(styled, at: heading.offset + (heading.title as NSString).length - 1), expected, "the whole line")
            }
        }
        let demo = try demoReview()
        let step = (demo.text as NSString).range(of: "Step 1").location
        XCTAssertEqual(font(ReviewDocumentStyler.attributed(demo, traits: traits), at: step), ReviewDocumentStyler.bodyFont(traits: traits))
        XCTAssertNotEqual(ReviewDocumentStyler.headingFont(level: 1, traits: traits), ReviewDocumentStyler.headingFont(level: 3, traits: traits))
    }

    func testListLinesHangTheirWrappedText() {
        let document = fixture()
        let styled = ReviewDocumentStyler.attributed(document, traits: traits)
        let text = document.text as NSString
        for marker in ["• ", "1. ", "☐ "] {
            let location = text.range(of: marker).location
            XCTAssertNotEqual(location, NSNotFound, marker)
            XCTAssertEqual(headIndent(styled, at: location), width(marker), accuracy: 0.01, marker)
        }
        XCTAssertEqual(headIndent(styled, at: text.range(of: "Intro").location), 0, "a paragraph does not hang")
        XCTAssertNil(ReviewDocumentStyler.listPrefix(of: "Step 2: the Stop hook"))
        XCTAssertEqual(ReviewDocumentStyler.listPrefix(of: "12. Twelfth"), "12. ")
    }

    /// Review focus 3: an empty document, no headings, a last heading
    /// without a newline, and a nested item whose indent includes its
    /// spaces.
    func testEdgeDocumentsKeepTheirTextAndIndentNestedItems() {
        XCTAssertEqual(ReviewDocumentStyler.attributed(PlainTextDocument(text: "", headings: []), traits: traits).length, 0)

        let plain = ReviewDocumentStyler.attributed(PlainTextDocument(text: "Just a paragraph.\n", headings: []), traits: traits)
        XCTAssertEqual(font(plain, at: 0), ReviewDocumentStyler.bodyFont(traits: traits))

        let tail = PlainTextDocument(text: "Body\n\nLast", headings: [.init(offset: 6, level: 2, title: "Last")])
        let styledTail = ReviewDocumentStyler.attributed(tail, traits: traits)
        XCTAssertEqual(styledTail.string, tail.text)
        XCTAssertEqual(font(styledTail, at: 9), ReviewDocumentStyler.headingFont(level: 2, traits: traits), "a last heading runs to the end")

        let nested = ReviewDocumentStyler.attributed(PlainTextDocument(text: "• Outer\n    • Inner item\n", headings: []), traits: traits)
        XCTAssertEqual(headIndent(nested, at: 0), width("• "), accuracy: 0.01)
        XCTAssertEqual(headIndent(nested, at: 8), width("    • "), accuracy: 0.01)
        XCTAssertGreaterThan(width("    • "), width("• "))
    }

    /// An anchor taken from a selection in the styled view is the anchor of
    /// the same range in the plain text.
    func testASelectionAnchorsAsOnThePlainText() throws {
        let document = try demoReview()
        let styled = ReviewDocumentStyler.attributed(document, traits: traits)
        let selection = (styled.string as NSString).range(of: "the Stop hook")
        XCTAssertNotEqual(selection.location, NSNotFound)
        let anchor = try XCTUnwrap(CommentAnchorBuilder.anchor(selection: selection, in: document))
        XCTAssertEqual(anchor, CommentAnchorBuilder.anchor(selection: (document.text as NSString).range(of: "the Stop hook"), in: document))
        XCTAssertEqual(anchor.heading, "Steps")
    }

    /// Phases 1–2 review and review focus 2: the same text at a new Dynamic
    /// Type size restyles; the attributed fonts do not follow a size change
    /// by themselves. The text stays `document.text`.
    func testADynamicTypeChangeRestylesTheSameText() {
        let document = fixture()
        XCTAssertTrue(ReviewDocumentStyler.needsRestyle(shown: "", styledCategory: nil, document: document, category: .large), "first show")
        XCTAssertFalse(ReviewDocumentStyler.needsRestyle(shown: document.text, styledCategory: .large, document: document, category: .large))
        XCTAssertTrue(
            ReviewDocumentStyler.needsRestyle(shown: document.text, styledCategory: .large, document: document, category: .accessibilityLarge),
            "same text, a new size"
        )
        XCTAssertTrue(ReviewDocumentStyler.needsRestyle(shown: "Old round", styledCategory: .large, document: document, category: .large))

        let large = ReviewDocumentStyler.attributed(document, traits: UITraitCollection(preferredContentSizeCategory: .large))
        let huge = ReviewDocumentStyler.attributed(document, traits: UITraitCollection(preferredContentSizeCategory: .accessibilityLarge))
        XCTAssertEqual(huge.string, document.text)
        XCTAssertGreaterThan(font(huge, at: 0)?.pointSize ?? 0, font(large, at: 0)?.pointSize ?? 0, "the restyle is at the new size")
    }
}
