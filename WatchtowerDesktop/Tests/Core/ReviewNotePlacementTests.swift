import XCTest
@testable import WatchtowerCore

final class ReviewNotePlacementTests: XCTestCase {
    func testSameTreeKeepsLines() {
        let out = ReviewNotePlacement.place(
            [(id: 1, quote: "gone", startLine: 4, endLine: 6, treeSHA: "t1")], currentTree: "t1"
        ) { _ in nil }
        XCTAssertEqual(out[1], ReviewCommentAnchor.Placement(startLine: 4, endLine: 6))
    }

    func testMovedQuoteFollows() {
        let text = "a\nb\nc\nlet x = 1\nd\n"
        let out = ReviewNotePlacement.place(
            [(id: 2, quote: "let x = 1", startLine: 1, endLine: 1, treeSHA: "t1")], currentTree: "t2"
        ) { _ in text }
        XCTAssertEqual(out[2], ReviewCommentAnchor.Placement(startLine: 4, endLine: 4))
    }

    func testLostQuoteIsAbsent() {
        let out = ReviewNotePlacement.place(
            [(id: 3, quote: "missing", startLine: 1, endLine: 1, treeSHA: "t1"),
             (id: 4, quote: "x", startLine: 1, endLine: 1, treeSHA: "t1")],
            currentTree: "t2"
        ) { $0 == 3 ? "other text" : nil }
        XCTAssertTrue(out.isEmpty)
    }
}
