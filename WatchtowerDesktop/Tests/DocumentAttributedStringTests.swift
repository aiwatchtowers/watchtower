import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
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

/// #181: the comment view lays markdown out like the read view.
@MainActor
final class DocumentAttributedStringLayoutTests: XCTestCase {
    private func paragraphStyle(_ out: NSAttributedString, at text: String) -> NSParagraphStyle? {
        let location = (out.string as NSString).range(of: text).location
        return out.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
    }

    func testTableCellsShareOneTextTable() throws {
        let out = DocumentAttributedString.make(
            DocumentRendering.render("| Name | Owner |\n|---|---|\n| retry | ops |"), highlights: [:], activeThreadID: nil
        )
        let blocks = try ["Name", "Owner", "retry", "ops"].map { word in
            try XCTUnwrap(paragraphStyle(out, at: word)?.textBlocks.last as? NSTextTableBlock, word)
        }
        XCTAssertEqual(blocks.map(\.startingRow), [0, 0, 1, 1])
        XCTAssertEqual(blocks.map(\.startingColumn), [0, 1, 0, 1])
        XCTAssertTrue(blocks.allSatisfy { $0.table === blocks[0].table })
        XCTAssertEqual(blocks[0].table.numberOfColumns, 2)
        let header = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(header?.fontDescriptor.symbolicTraits.contains(.bold) ?? false, "the header row is bold")
    }

    func testListItemsHangUnderTheirMarker() throws {
        let out = DocumentAttributedString.make(
            DocumentRendering.render("- a long item\n  - nested"), highlights: [:], activeThreadID: nil
        )
        let outer = try XCTUnwrap(paragraphStyle(out, at: "a long item"))
        let nested = try XCTUnwrap(paragraphStyle(out, at: "nested"))
        XCTAssertEqual(outer.firstLineHeadIndent, 0)
        XCTAssertGreaterThan(outer.headIndent, 0, "wrapped lines start under the text, not under the bullet")
        XCTAssertGreaterThan(nested.headIndent, outer.headIndent)
    }

    func testCodeBlocksAndQuotesAreBoxes() throws {
        let out = DocumentAttributedString.make(
            DocumentRendering.render("```\nlet x = 1\n```\n\n> quoted\n\n---"), highlights: [:], activeThreadID: nil
        )
        XCTAssertNotNil(paragraphStyle(out, at: "let x")?.textBlocks.first)
        XCTAssertNotNil(paragraphStyle(out, at: "quoted")?.textBlocks.first)
        XCTAssertNotNil(paragraphStyle(out, at: "\u{00A0}")?.textBlocks.first, "a rule is a bordered block")
        XCTAssertEqual(out.attribute(.foregroundColor, at: (out.string as NSString).range(of: "quoted").location,
                                     effectiveRange: nil) as? NSColor, .secondaryLabelColor)
    }

    func testBoldInsideAHeadingKeepsTheHeadingSize() {
        let doc = DocumentRendering.render("# The **big** plan")
        let out = DocumentAttributedString.make(doc, highlights: [:], activeThreadID: nil)
        let font = out.attribute(.font, at: (doc.text as NSString).range(of: "big").location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, 22)
        XCTAssertTrue(font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
    }

    /// Equal renders never compare equal (text blocks compare by identity),
    /// so `DocumentTextView` relies on getting the same instance back.
    func testTheSameInputsReturnTheSameInstance() {
        let doc = DocumentRendering.render("| A |\n|---|\n| 1 |\n\n```\ncode\n```")
        let first = DocumentAttributedString.make(doc, highlights: [1: NSRange(location: 0, length: 1)], activeThreadID: 1)
        XCTAssertTrue(first === DocumentAttributedString.make(doc, highlights: [1: NSRange(location: 0, length: 1)],
                                                              activeThreadID: 1))
        XCTAssertFalse(first === DocumentAttributedString.make(doc, highlights: [1: NSRange(location: 0, length: 1)],
                                                               activeThreadID: nil), "another active thread is another render")
    }

    func testCodeIsHighlightedAndLinksShowTheirDestinationOnHover() {
        let doc = DocumentRendering.render("See [the spec](docs/spec.md).\n\n```go\nreturn nil\n```")
        let out = DocumentAttributedString.make(doc, highlights: [:], activeThreadID: nil)
        let text = out.string as NSString
        XCTAssertEqual(out.attribute(.toolTip, at: text.range(of: "the spec").location, effectiveRange: nil) as? String,
                       "docs/spec.md")
        XCTAssertEqual(out.attribute(.foregroundColor, at: text.range(of: "return").location, effectiveRange: nil) as? NSColor,
                       .systemPurple)
    }
}
