import XCTest
@testable import WatchtowerCore

/// Focus places and margin comment anchors of a review, taken on the ask's
/// rendered snapshot (spec 2026-10-03 Parts 8 and 10).
final class OwnerAskReviewTextTests: XCTestCase {
    private let doc = DocumentRendering.render("""
        # Plan

        Ship the **retry budget** first.

        ## Rollout

        Canary for a week, then everyone.
        """)

    private func text(_ range: NSRange?) -> String? {
        range.map { (doc.text as NSString).substring(with: $0) }
    }

    func testAFocusHeadingResolvesToItsHeading() {
        let range = OwnerAskReviewText.range(of: OwnerAskFocus(text: "Check the order", heading: "Rollout"), in: doc)
        XCTAssertEqual(text(range), "Rollout")
        XCTAssertEqual(range?.location, doc.headings.first { $0.title == "Rollout" }?.offset)
        XCTAssertEqual(text(OwnerAskReviewText.range(of: OwnerAskFocus(text: "x", heading: "## rollout "), in: doc)), "Rollout",
                       "the Markdown hashes, case and stray spaces do not matter")
    }

    func testAFocusQuoteResolvesAsWrittenOrAsTheMarkdownRendersIt() {
        XCTAssertEqual(text(OwnerAskReviewText.range(of: OwnerAskFocus(text: "x", quote: "Canary for a week"), in: doc)),
                       "Canary for a week")
        XCTAssertEqual(text(OwnerAskReviewText.range(of: OwnerAskFocus(text: "x", quote: "the **retry budget**"), in: doc)),
                       "the retry budget", "a quote copied from the Markdown source")
        XCTAssertEqual(text(OwnerAskReviewText.range(of: OwnerAskFocus(text: "x", quote: "Canary  for\na week"), in: doc)),
                       "Canary for a week", "whitespace runs read as one space")
    }

    func testAFocusNotInTheSnapshotHasNoPlace() {
        XCTAssertNil(OwnerAskReviewText.range(of: OwnerAskFocus(text: "x", quote: "not in the document"), in: doc))
        XCTAssertNil(OwnerAskReviewText.range(of: OwnerAskFocus(text: "x", heading: "Risks"), in: doc))
        XCTAssertNil(OwnerAskReviewText.range(of: OwnerAskFocus(text: "just look"), in: doc), "names no place")
    }

    func testAFocusQuoteWinsOverItsHeading() {
        let focus = OwnerAskFocus(text: "x", heading: "Plan", quote: "then everyone")
        XCTAssertEqual(text(OwnerAskReviewText.range(of: focus, in: doc)), "then everyone")
        let missing = OwnerAskFocus(text: "x", heading: "Plan", quote: "gone")
        XCTAssertEqual(text(OwnerAskReviewText.range(of: missing, in: doc)), "Plan", "the heading when the quote is gone")
    }

    func testACommentAnchorIsTakenOnTheSnapshotAndRoundTripsIntoTheAnswer() throws {
        let selection = (doc.text as NSString).range(of: "for a week")
        let anchor = try XCTUnwrap(OwnerAskReviewText.anchor(selection: selection, in: doc))
        XCTAssertEqual(anchor.quote, "for a week")
        XCTAssertEqual(anchor.heading, "Rollout")
        XCTAssertTrue(anchor.prefix.hasSuffix("Canary "))
        XCTAssertTrue(anchor.suffix.hasPrefix(", then everyone."))
        XCTAssertEqual(OwnerAskReviewText.range(of: anchor, in: doc), selection)

        let comment = OwnerAskAnswer.Comment(anchor: anchor, body: "Two weeks")
        XCTAssertEqual([comment.quote, comment.prefix, comment.suffix, comment.heading],
                       [anchor.quote, anchor.prefix, anchor.suffix, anchor.heading])
        XCTAssertEqual(OwnerAskReviewText.anchor(of: comment), anchor, "a stored comment reads back as its anchor")
        XCTAssertEqual(OwnerAskReviewText.range(of: OwnerAskReviewText.anchor(of: comment), in: doc), selection)
    }

    func testAnEmptyOrStaleSelectionTakesNoAnchor() {
        XCTAssertNil(OwnerAskReviewText.anchor(selection: NSRange(location: 3, length: 0), in: doc))
        XCTAssertNil(OwnerAskReviewText.anchor(selection: NSRange(location: 3, length: 10_000), in: doc))
    }
}
