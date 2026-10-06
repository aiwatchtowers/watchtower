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

/// #398: a quote or a code block spans the column whatever its inline
/// markup, and keeps doing so once the column widens: the review body is
/// first laid out at the zero width a `GeometryReader` starts with.
@MainActor
final class DocumentAttributedStringBlockWidthTests: XCTestCase {
    /// The standard superpowers plan header: a quote with bold inside.
    private static let planHeader = """
    # Atlas plan

    > **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development \
    (recommended) or superpowers:executing-plans to implement this plan task-by-task.

    **Goal:** keep the retry budget small.

    ```go
    // retry with a [small](budget) budget
    return nil
    ```

    ---
    """

    private static let column: CGFloat = 600

    /// Lays `out` out with no room at all, then at `column`, the way a
    /// `DocumentTextView` sees its width arrive (the default line fragment
    /// padding, as there). The storage is returned
    /// too: it owns the layout manager, not the other way round.
    private func layoutAfterWidening(_ out: NSAttributedString) -> (NSTextStorage, NSLayoutManager) {
        let storage = NSTextStorage(attributedString: out)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        container.size = NSSize(width: Self.column, height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return (storage, layout)
    }

    private func lineRect(_ layout: NSLayoutManager, _ out: NSAttributedString, at text: String) -> CGRect {
        let location = (out.string as NSString).range(of: text).location
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
    }

    func testAQuoteParagraphWithInlineMarkupHasOneBlock() throws {
        let out = DocumentAttributedString.make(DocumentRendering.render(Self.planHeader), highlights: [:],
                                                activeThreadID: nil, typography: ReviewTypography.style)
        let text = out.string as NSString
        let paragraph = text.paragraphRange(for: text.range(of: "For agentic"))
        var effective = NSRange()
        let style = try XCTUnwrap(out.attribute(.paragraphStyle, at: paragraph.location, longestEffectiveRange: &effective,
                                                in: paragraph) as? NSParagraphStyle)
        XCTAssertEqual(effective, paragraph, "one paragraph style across the bold and the plain text")
        XCTAssertEqual(style.textBlocks.count, 1)
    }

    func testQuotesCodeBlocksAndRulesSpanTheColumnAfterItWidens() {
        for typography in [DocumentTypography.standard, ReviewTypography.style] {
            let out = DocumentAttributedString.make(DocumentRendering.render(Self.planHeader), highlights: [:],
                                                    activeThreadID: nil, typography: typography)
            let (storage, layout) = layoutAfterWidening(out)
            XCTAssertEqual(storage.length, out.length)
            for text in ["For agentic", "// retry", "\u{00A0}"] {
                let rect = lineRect(layout, out, at: text)
                XCTAssertGreaterThan(rect.width, Self.column - 40, "\(text) spans the column")
                XCTAssertLessThanOrEqual(rect.maxX, Self.column, "\(text) stays inside it")
            }
            XCTAssertLessThan(lineRect(layout, out, at: "Goal").minY, 300, "the quote is a few lines, not a letter per line")
        }
    }

    /// A table sizes its columns by its automatic algorithm, not to the
    /// full column, so the guard is that widening lays it out as a fresh
    /// layout at that width does.
    func testTablesLayOutAfterTheColumnWidensAsAtThatWidth() {
        let long = "keep the retry budget small enough that a stuck sync never eats the whole cycle, then log it"
        let markdown = "| Name | Rule |\n|---|---|\n| retry | \(long) |"
        for typography in [DocumentTypography.standard, ReviewTypography.style] {
            let out = DocumentAttributedString.make(DocumentRendering.render(markdown), highlights: [:],
                                                    activeThreadID: nil, typography: typography)
            let (storage, widened) = layoutAfterWidening(out)
            let fresh = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: Self.column, height: CGFloat.greatestFiniteMagnitude))
            fresh.addTextContainer(container)
            let freshStorage = NSTextStorage(attributedString: out)
            freshStorage.addLayoutManager(fresh)
            fresh.ensureLayout(for: container)
            XCTAssertEqual(storage.length, freshStorage.length)
            for text in ["Name", "retry", "keep the retry", "then log it"] {
                XCTAssertEqual(lineRect(widened, out, at: text), lineRect(fresh, out, at: text), text)
            }
            let cell = lineRect(widened, out, at: "keep the retry")
            XCTAssertGreaterThan(cell.width, Self.column / 3, "the long cell is not squeezed")
            XCTAssertLessThanOrEqual(cell.maxX, Self.column, "the table stays inside the column")
        }
    }

    func testNestedBlocksStayInsideTheColumn() {
        let markdown = "- item\n\n  > quoted in a list\n\n> outer\n>\n> > nested quote\n\n- item\n\n  ```\n  code in a list\n  ```"
        let out = DocumentAttributedString.make(DocumentRendering.render(markdown), highlights: [:], activeThreadID: nil)
        let (storage, layout) = layoutAfterWidening(out)
        XCTAssertEqual(storage.length, out.length)
        for text in ["quoted in a list", "nested quote", "code in a list"] {
            let rect = lineRect(layout, out, at: text)
            XCTAssertGreaterThan(rect.width, Self.column / 2, "\(text) is not squeezed")
            XCTAssertLessThanOrEqual(rect.maxX, Self.column, "\(text) stays inside the column")
        }
    }
}
