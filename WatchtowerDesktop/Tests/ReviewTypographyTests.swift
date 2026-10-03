import XCTest
import AppKit
@testable import WatchtowerDesktop
import WatchtowerCore

/// The owner-ask review body's reading layout (spec 2026-10-03 Part 8),
/// read off the attributes `DocumentAttributedString` gives with it.
@MainActor
final class ReviewTypographyTests: XCTestCase {
    private static let markdown = """
        # Plan

        Ship the retry budget first.

        ## Rollout

        - canary for a week

        ### Risks

        ```
        let x = 1
        ```

        | Name | Owner |
        |---|---|
        | backoff | ops |
        """

    private let out = DocumentAttributedString.make(
        DocumentRendering.render(markdown), highlights: [:], activeThreadID: nil, typography: ReviewTypography.style
    )

    private func location(_ text: String) -> Int {
        (out.string as NSString).range(of: text).location
    }

    private func font(_ text: String) -> NSFont? {
        out.attribute(.font, at: location(text), effectiveRange: nil) as? NSFont
    }

    private func style(_ text: String) throws -> NSParagraphStyle {
        try XCTUnwrap(out.attribute(.paragraphStyle, at: location(text), effectiveRange: nil) as? NSParagraphStyle, text)
    }

    /// The line height a paragraph style gives `font`, as a multiple of its size.
    private func lineHeight(_ style: NSParagraphStyle, _ font: NSFont) -> CGFloat {
        style.lineHeightMultiple * NSLayoutManager().defaultLineHeight(for: font) / font.pointSize
    }

    func testFontSizesPerStyle() {
        XCTAssertEqual(font("Ship")?.pointSize, 14, "body")
        XCTAssertEqual(font("Plan")?.pointSize, 22)
        XCTAssertEqual(font("Rollout")?.pointSize, 17)
        XCTAssertEqual(font("Risks")?.pointSize, 15)
        XCTAssertTrue(font("let x")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false, "code is monospaced")
    }

    func testBodyLinesAreOneAndAHalfHigh() throws {
        let body = try style("Ship")
        XCTAssertEqual(lineHeight(body, try XCTUnwrap(font("Ship"))), 1.55, accuracy: 0.01)
        XCTAssertGreaterThan(body.paragraphSpacing, 0, "paragraphs breathe")
    }

    func testHeadingsHaveMoreSpaceAboveThanBelow() throws {
        for heading in ["Plan", "Rollout", "Risks"] {
            let style = try style(heading)
            XCTAssertGreaterThan(style.paragraphSpacingBefore, style.paragraphSpacing, heading)
        }
        XCTAssertGreaterThan(try style("Plan").paragraphSpacingBefore, try style("Risks").paragraphSpacingBefore,
                             "a bigger heading opens a bigger gap")
    }

    func testListsHangAndCodeIsATintedBox() throws {
        let item = try style("canary")
        XCTAssertGreaterThan(item.headIndent, item.firstLineHeadIndent, "wrapped lines hang under the text")
        let code = try XCTUnwrap(try style("let x").textBlocks.first)
        XCTAssertNotNil(code.backgroundColor, "a code block is tinted")
        XCTAssertEqual(try style("let x").paragraphSpacing, 0, "code lines stay together")
    }

    func testTableCellsAreTextTableBlocks() throws {
        let blocks = try ["Name", "Owner", "backoff", "ops"].map { word in
            try XCTUnwrap(try style(word).textBlocks.last as? NSTextTableBlock, word)
        }
        XCTAssertEqual(blocks.map(\.startingRow), [0, 0, 1, 1])
        XCTAssertEqual(blocks.map(\.startingColumn), [0, 1, 0, 1])
        XCTAssertTrue(blocks.allSatisfy { $0.table === blocks[0].table })
    }

    func testTheBlankLineBetweenBlocksIsSmall() throws {
        let blank = location("first.") + "first.".utf16.count + 1
        let font = try XCTUnwrap(out.attribute(.font, at: blank, effectiveRange: nil) as? NSFont)
        XCTAssertLessThan(font.pointSize, 14, "the rhythm comes from paragraph spacing, not a full empty line")
    }

    func testTheStandardLayoutIsUnchanged() throws {
        let standard = DocumentAttributedString.make(DocumentRendering.render(Self.markdown), highlights: [:], activeThreadID: nil)
        let at = (standard.string as NSString).range(of: "Rollout").location
        XCTAssertEqual((standard.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize, 18)
        XCTAssertNil(standard.attribute(.paragraphStyle, at: (standard.string as NSString).range(of: "Ship").location,
                                        effectiveRange: nil), "the comment views keep the font's own line height")
        XCTAssertFalse(standard === out)
    }

    func testTheColumnIsAtMost680PointsAndCentered() {
        XCTAssertEqual(ReviewTypography.horizontalInset(forWidth: 1080), 200, "(1080 - 680) / 2")
        XCTAssertEqual(ReviewTypography.horizontalInset(forWidth: 500), ReadableColumn.minInset, "a narrow pane keeps its gutter")
    }
}
