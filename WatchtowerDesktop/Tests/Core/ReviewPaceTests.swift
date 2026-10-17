import XCTest
@testable import WatchtowerCore

final class ReviewPaceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testCountsOnlyKeyAndRecentlyActiveTime() {
        var pace = ReviewPace(activeSeconds: 0)
        pace.noteInteraction(at: t0)
        pace.tick(at: t0, isKey: true)
        for step in stride(from: 10.0, through: 100.0, by: 10.0) { pace.tick(at: t0 + step, isKey: true) }
        XCTAssertEqual(pace.activeSeconds, 100)
        for step in stride(from: 130.0, through: 200.0, by: 10.0) { pace.tick(at: t0 + step, isKey: true) }
        XCTAssertEqual(pace.activeSeconds, 100)
        pace.noteInteraction(at: t0 + 205)
        pace.tick(at: t0 + 210, isKey: false)
        pace.tick(at: t0 + 215, isKey: false)
        XCTAssertEqual(pace.activeSeconds, 100)
    }

    func testCapsOneTickGap() {
        var pace = ReviewPace(activeSeconds: 0)
        pace.noteInteraction(at: t0)
        pace.tick(at: t0, isKey: true)
        pace.tick(at: t0 + 5, isKey: true)
        pace.tick(at: t0 + 65, isKey: true)
        XCTAssertEqual(pace.activeSeconds, 20)
    }

    func testBreakHintAt3600() {
        var pace = ReviewPace(activeSeconds: 3599)
        XCTAssertFalse(pace.breakHintDue)
        pace.noteInteraction(at: t0)
        pace.tick(at: t0, isKey: true)
        pace.tick(at: t0 + 1, isKey: true)
        XCTAssertEqual(pace.activeSeconds, 3600)
        XCTAssertTrue(pace.breakHintDue)
    }

    func testProgressCountsViewedLinesAndDoneChapters() {
        let files = [
            ReviewDiffFile(path: "a/x.go", additions: 10, deletions: 5),
            ReviewDiffFile(path: "a/y.go", additions: 3, deletions: 2),
            ReviewDiffFile(path: "b/z.go", additions: 20, deletions: 0)
        ]
        let chapters = ReviewChapters.mechanical(files)
        let progress = ReviewProgress.make(files: files, chapters: chapters) { $0.hasPrefix("a/") }
        XCTAssertEqual(progress, ReviewProgress(viewedLines: 20, totalLines: 40, chaptersDone: 1, chapterCount: 2))
    }
}
