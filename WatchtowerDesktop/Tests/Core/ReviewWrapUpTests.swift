import XCTest
@testable import WatchtowerCore

final class ReviewWrapUpTests: XCTestCase {
    private func comment(_ id: Int64, path: String?, status: ReviewComment.Status = .draft) -> ReviewComment {
        ReviewComment(
            id: id, roundID: 1, path: path, side: "new", startLine: 1, endLine: 1, quote: "", quotePrefix: "",
            quoteSuffix: "", treeSHA: "", lens: "correctness", body: "c\(id)", status: status, carriedFrom: nil, agentReply: ""
        )
    }

    func testIntentItemsOnePerLinkedTarget() {
        let items = ReviewWrapUp.intentItems([
            ReviewContextItem(targetId: 12, text: "Add X"), ReviewContextItem(targetId: 15, text: "Fix Y")
        ])
        XCTAssertEqual(items.map(\.key), ["target:12", "target:15"])
        XCTAssertEqual(items.map(\.text), ["Add X", "Fix Y"])
    }

    func testIntentItemsFromCoverage() {
        let context = [ReviewContextItem(targetId: 12, text: "Add X")]
        let a = ReviewWrapUp.intentItems(context, coverage: [(item: "Ship X", status: "covered"), (item: "Docs", status: "missing")])
        let b = ReviewWrapUp.intentItems(context, coverage: [(item: "Docs", status: "partial")])
        XCTAssertEqual(a.map(\.text), ["Ship X", "Docs"])
        XCTAssertEqual(a.map(\.aiStatus), ["covered", "missing"])
        XCTAssertTrue(a[0].key.hasPrefix("cov:"))
        XCTAssertEqual(a[0].key.count, 4 + 16)
        XCTAssertEqual(a[1].key, b[0].key)
        let fallback = ReviewWrapUp.intentItems(context, coverage: [])
        XCTAssertEqual(fallback.map(\.key), ["target:12"])
        XCTAssertNil(fallback[0].aiStatus)
    }

    func testCommentsGroupedByChapterInChapterOrder() {
        let chapters = [
            ReviewChapter(key: "dir:a", title: "a", paths: ["a/x.go"], changedLines: 1, core: false),
            ReviewChapter(key: "dir:b", title: "b", paths: ["b/y.go"], changedLines: 1, core: false),
            ReviewChapter(key: "dir:c", title: "c", paths: ["c/z.go"], changedLines: 1, core: false)
        ]
        let groups = ReviewWrapUp.commentsByChapter([
            comment(1, path: "b/y.go"), comment(2, path: nil), comment(3, path: "a/x.go"),
            comment(4, path: "gone.go"), comment(5, path: "a/x.go", status: .resolved), comment(6, path: "b/y.go")
        ], chapters: chapters)
        XCTAssertEqual(groups.map(\.title), ["a", "b", "General"])
        XCTAssertEqual(groups[0].comments.map(\.id), [3])
        XCTAssertEqual(groups[1].comments.map(\.id), [1, 6])
        XCTAssertEqual(groups[2].comments.map(\.id), [2, 4])
    }

    func testIntentCommentBody() {
        let item = ReviewIntentItem(key: "target:1", text: "Add X")
        XCTAssertEqual(ReviewWrapUp.intentCommentBody(partial: false, item: item, note: ""), "Not done: Add X")
        XCTAssertEqual(
            ReviewWrapUp.intentCommentBody(partial: true, item: item, note: "tests missing"),
            "Partly done: Add X — tests missing"
        )
    }
}
