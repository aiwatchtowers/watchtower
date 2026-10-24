import WatchtowerCore
import XCTest
@testable import WatchtowerDesktop

/// Review polish (#958): Full file per file, Deep's chapter Viewed (Chapter
/// viewed → and the chapter list toggle). Split out of ReviewChangesModelTests
/// to keep that file under the length cap.
extension ReviewChangesModelTests {
    /// Full file is per file view (board #959): another file opens on Changes.
    func testSelectingAnotherFileResetsFullFile() async throws {
        let h = try harness()
        h.baseScript(paths: ["a.go", "b.go"])
        h.cli.script("file", [fileJSON(old: "a\n", new: "a2\n"), fileJSON(old: "b\n", new: "b2\n")])
        await h.model.open()
        await h.model.select("a.go")
        h.model.fullFile = true
        await h.model.select("a.go")
        XCTAssertTrue(h.model.fullFile, "re-selecting the same file keeps Full file")
        await h.model.select("b.go")
        XCTAssertFalse(h.model.fullFile)
    }

    private func openThreeChapters(_ h: ReviewModelHarness) async -> [String] {
        await openDeep(h, paths: ["cmd/a.go", "cmd/b.go", "lib/c.go", "pkg/d.go"])
        return h.model.chapters.map(\.key)
    }

    func testMarkChapterViewedMarksEveryFileAndMovesOn() async throws {
        let h = try harness()
        let keys = await openThreeChapters(h)
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(h.model.currentChapterKey, keys[0])
        let first = try XCTUnwrap(h.model.chapters.first)
        try await h.model.toggleViewed(first.paths[0])
        try await h.model.markChapterViewed(keys[0])
        for path in first.paths { XCTAssertTrue(h.model.isViewed(path)) }
        XCTAssertEqual(h.model.currentChapterKey, keys[1])
        XCTAssertFalse(h.model.isViewed(h.model.chapters[1].paths[0]))
    }

    func testMarkChapterViewedSkipsDoneChaptersAndWraps() async throws {
        let h = try harness()
        let keys = await openThreeChapters(h)
        try await h.model.setViewed(h.model.chapters[1].paths, on: true)
        try await h.model.markChapterViewed(keys[0])
        XCTAssertEqual(h.model.currentChapterKey, keys[2], "the done middle chapter is skipped")
        try await h.model.markChapterViewed(keys[2])
        XCTAssertEqual(h.model.phase, .wrapup, "nothing undone is left")
        try await h.model.toggleChapterViewed(keys[1])
        XCTAssertEqual(h.model.nextUndoneChapter(after: keys[2]), keys[1])
        XCTAssertEqual(h.model.nextUndoneChapter(after: keys[1]), nil, "the only undone chapter is the asked one")
    }

    func testMarkLastChapterGoesToWrapUp() async throws {
        let h = try harness()
        let keys = await openThreeChapters(h)
        try await h.model.setViewed(h.model.chapters[0].paths + h.model.chapters[1].paths, on: true)
        try await h.model.selectChapter(keys[2])
        try await h.model.markChapterViewed(keys[2])
        XCTAssertEqual(h.model.phase, .wrapup)
    }

    func testToggleChapterViewedOnDoneChapterUnviewsAllAndStays() async throws {
        let h = try harness()
        let keys = await openThreeChapters(h)
        try await h.model.markChapterViewed(keys[0])
        XCTAssertEqual(h.model.currentChapterKey, keys[1])
        try await h.model.toggleChapterViewed(keys[0])
        for path in h.model.chapters[0].paths { XCTAssertFalse(h.model.isViewed(path)) }
        XCTAssertEqual(h.model.currentChapterKey, keys[1], "un-viewing does not move")
        try await h.model.toggleChapterViewed(keys[0])
        XCTAssertTrue(h.model.chapters[0].paths.allSatisfy { h.model.isViewed($0) })
    }

    func testChangedFileUnmarksTheChapter() async throws {
        let h = try harness()
        h.cli.script("start", [deepStartJSON(), deepStartJSON(tree: "u")])
        h.cli.script("context", [deepContextJSON()])
        h.cli.script("diff", [diffJSON(["cmd/x.go", "pkg/y.go"]), diffJSON(["cmd/x.go", "pkg/y.go"], hunk: "changed")])
        await h.model.open()
        try await h.model.markChapterViewed("dir:cmd")
        let chapter = try XCTUnwrap(h.model.chapters.first { $0.key == "dir:cmd" })
        XCTAssertTrue(ReviewChapters.done(chapter) { h.model.isViewed($0) })
        await h.model.refresh()
        let after = try XCTUnwrap(h.model.chapters.first { $0.key == "dir:cmd" })
        XCTAssertFalse(ReviewChapters.done(after) { h.model.isViewed($0) })
    }

    func testSetViewedWithAnUnknownPathWritesNothing() async throws {
        let h = try harness()
        _ = await openThreeChapters(h)
        await assertThrowsAsync { try await h.model.setViewed(["cmd/a.go", "nope.go"], on: true) }
        XCTAssertFalse(h.model.isViewed("cmd/a.go"))
    }
}
