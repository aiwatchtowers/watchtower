import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore

final class DocumentAttributedStringTests: XCTestCase {
    func testHighlightsMarkAnchoredRangesAndTheActiveOneIsStronger() {
        let doc = DocumentRendering.render("# Plan\n\nKeep the retry budget small.")
        let range = (doc.text as NSString).range(of: "retry budget")
        let other = (doc.text as NSString).range(of: "small")
        let out = DocumentAttributedString.make(doc, highlights: [1: range, 2: other], activeThreadID: 1)
        XCTAssertEqual(out.string, doc.text)
        let active = out.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor
        let passive = out.attribute(.backgroundColor, at: other.location, effectiveRange: nil) as? NSColor
        XCTAssertEqual(active, DocumentAttributedString.activeHighlight)
        XCTAssertEqual(passive, DocumentAttributedString.highlight)
        let headingFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(headingFont?.pointSize, 22)
    }

    func testOutOfBoundsRangesAreIgnoredNotCrashed() {
        let doc = DocumentRendering.render("Short.")
        let out = DocumentAttributedString.make(doc, highlights: [1: NSRange(location: 3, length: 500)], activeThreadID: nil)
        XCTAssertNil(out.attribute(.backgroundColor, at: 3, effectiveRange: nil))
    }

    func testDraftsGetTheirOwnHighlight() {
        let doc = DocumentRendering.render("Keep the retry budget small.")
        let range = (doc.text as NSString).range(of: "budget")
        let out = DocumentAttributedString.make(doc, highlights: [:], activeThreadID: nil,
                                                drafts: [range, NSRange(location: 2, length: 900)])
        XCTAssertEqual(out.attribute(.backgroundColor, at: range.location, effectiveRange: nil) as? NSColor,
                       DocumentAttributedString.draftHighlight)
        XCTAssertNil(out.attribute(.backgroundColor, at: 2, effectiveRange: nil), "an out-of-bounds draft is ignored")
    }
}
