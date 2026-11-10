import XCTest
@testable import WatchtowerCore

final class ReviewChaptersTests: XCTestCase {
    private func file(_ path: String, add: Int = 10, del: Int = 0, collapsed: String? = nil) -> ReviewDiffFile {
        ReviewDiffFile(path: path, additions: add, deletions: del, collapsedReason: collapsed)
    }

    func testDoneWhenEveryFileViewed() {
        let chapter = ReviewChapter(key: "dir:a", title: "a", paths: ["a/x", "a/y"], changedLines: 2, core: false)
        XCTAssertFalse(ReviewChapters.done(chapter) { $0 == "a/x" })
        XCTAssertTrue(ReviewChapters.done(chapter) { _ in true })
    }

    func testProgressIgnoresCollapsedFiles() {
        let files = [file("a/x", add: 10), file("go.sum", add: 500, collapsed: "lock")]
        let progress = ReviewProgress.make(files: files, chapters: []) { _ in true }
        XCTAssertEqual(progress.totalLines, 10)
        XCTAssertEqual(progress.viewedLines, 10)
    }

    func testEstimateMinutes() {
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 0), 0)
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 1), 1)
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 400), 60)
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 1000), 150)
    }
}
