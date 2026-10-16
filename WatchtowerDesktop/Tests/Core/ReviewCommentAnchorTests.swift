import XCTest
@testable import WatchtowerCore

final class ReviewCommentAnchorTests: XCTestCase {
    private let original = "line1\nfunc a() {\n  return 1\n}\nline5\n"

    func testAnchorQuotesTheLines() {
        let a = ReviewCommentAnchor.anchor(text: original, startLine: 2, endLine: 3)
        XCTAssertEqual(a.quote, "func a() {\n  return 1")
    }

    func testMovedWhenLinesShift() {
        let c = comment(id: 1, start: 2, end: 3)
        let shifted = "new0\nnew1\n" + original
        let plan = ReviewCommentAnchor.plan([c]) { _ in shifted }
        XCTAssertEqual(plan.moved[1], .init(startLine: 4, endLine: 5))
        XCTAssertTrue(plan.lost.isEmpty)
    }

    func testLostWhenQuoteGone() {
        let plan = ReviewCommentAnchor.plan([comment(id: 2, start: 2, end: 3)]) { _ in "totally\ndifferent\n" }
        XCTAssertEqual(plan.lost, [2])
    }

    func testLostWhenFileGone() {
        let plan = ReviewCommentAnchor.plan([comment(id: 3, start: 1, end: 1)]) { _ in nil }
        XCTAssertEqual(plan.lost, [3])
    }

    func testDesignCommentNeverMoves() {
        let c = ReviewComment.fixture(id: 4, path: nil, start: 0, end: 0,
                                      anchor: .init(quote: "", prefix: "", suffix: "", heading: ""))
        let plan = ReviewCommentAnchor.plan([c]) { _ in nil }
        XCTAssertTrue(plan.lost.isEmpty && plan.moved.isEmpty)
    }

    private func comment(id: Int64, start: Int, end: Int) -> ReviewComment {
        ReviewComment.fixture(id: id, path: "a.go", start: start, end: end,
                              anchor: ReviewCommentAnchor.anchor(text: original, startLine: start, endLine: end))
    }
}
