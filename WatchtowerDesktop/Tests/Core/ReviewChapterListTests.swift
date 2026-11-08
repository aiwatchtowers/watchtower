import XCTest
@testable import WatchtowerCore

final class ReviewChapterListTests: XCTestCase {
    private func chapter(_ key: String, _ level: ReviewDangerLevel, _ paths: [String]) -> ReviewMap.Chapter {
        ReviewMap.Chapter(
            key: key, title: key, level: level, core: level == .breaking, paths: paths, changedLines: paths.count,
            lane: nil, targetId: nil, jiraKey: nil, signalsSummary: [:]
        )
    }

    private func map(_ chapters: [ReviewMap.Chapter]) -> ReviewMap {
        let files = chapters.flatMap { c in
            c.paths.map { ReviewMap.File(path: $0, chapter: c.key, level: c.level, signals: [], lane: nil, also: []) }
        }
        return ReviewMap(chapters: chapters, files: files)
    }

    func testSectionsOfTheGolden() throws {
        let sections = ReviewChapterList.sections(try ReviewMapTests.goldenMap())
        XCTAssertEqual(sections.map(\.title), ["Breaking and significant", "Other changes", "Can skip"])
        XCTAssertEqual(sections[0].chapters.map(\.key), ["dir:api", "lane:ABC-1-login", "dir:", "dir:internal/db/migrations"])
        XCTAssertEqual(sections[1].chapters.map(\.key), ["agent:1", "lane:task-b"])
        XCTAssertEqual(sections[2].chapters.map(\.key), ["collapsed"])
        XCTAssertEqual(sections.map(\.foldedByDefault), [false, false, true])
    }

    func testEmptySectionsAreLeftOut() {
        let sections = ReviewChapterList.sections(map([chapter("dir:a", .normal, ["a/1"]), chapter("dir:b", .normal, ["b/1"])]))
        XCTAssertEqual(sections.map(\.kind), [.other])
    }

    func testCounterExcludesCollapsed() throws {
        let golden = try ReviewMapTests.goldenMap()
        let none = ReviewChapterList.counter(map: golden) { _ in false }
        XCTAssertEqual(none.chapters, 6)
        XCTAssertEqual(none.files, 7)

        let viewed: Set = ["api/api.go", "pay/pay.go"]
        let some = ReviewChapterList.counter(map: golden) { viewed.contains($0) }
        XCTAssertEqual(some.chapters, 5) // lane:task-b still has shared.go
        XCTAssertEqual(some.files, 5)

        let all = ReviewChapterList.counter(map: golden) { $0 != "testdata/golden.json" }
        XCTAssertEqual(all.chapters, 0)
        XCTAssertEqual(all.files, 0)
    }

    func testNextFollowsDangerOrder() throws {
        let golden = try ReviewMapTests.goldenMap()
        XCTAssertEqual(ReviewChapterList.next(map: golden) { _ in false }, "dir:api")
        let viewed: Set = ["api/api.go", "login/auth.go", "README.md"]
        XCTAssertEqual(ReviewChapterList.next(map: golden) { viewed.contains($0) }, "dir:internal/db/migrations")
        // Every chapter outside "Can skip" done: nothing next, even with "Can skip" unread.
        XCTAssertNil(ReviewChapterList.next(map: golden) { $0 != "testdata/golden.json" })
    }

    func testOneChapterHidesTheList() throws {
        XCTAssertTrue(ReviewChapterList.showsList(try ReviewMapTests.goldenMap()))
        XCTAssertFalse(ReviewChapterList.showsList(map([chapter("dir:a", .normal, ["a/1"]), chapter("collapsed", .normal, ["go.sum"])])))
        XCTAssertFalse(ReviewChapterList.showsList(map([chapter("collapsed", .normal, ["go.sum"])])))
        XCTAssertFalse(ReviewChapterList.showsList(map([])))
        XCTAssertTrue(ReviewChapterList.showsList(map([chapter("dir:a", .normal, ["a/1"]), chapter("dir:b", .normal, ["b/1"])])))
    }
}
