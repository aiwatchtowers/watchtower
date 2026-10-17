import XCTest
@testable import WatchtowerCore

final class ReviewChaptersTests: XCTestCase {
    private func file(_ path: String, add: Int = 10, del: Int = 0, collapsed: String? = nil) -> ReviewDiffFile {
        ReviewDiffFile(path: path, additions: add, deletions: del, collapsedReason: collapsed)
    }

    func testGroupsByDirectoryInPathOrder() {
        let chapters = ReviewChapters.mechanical([
            file("cmd/a.go"), file("internal/x/b.go"), file("cmd/c.go"), file("README.md")
        ])
        XCTAssertEqual(chapters.map(\.key), ["dir:", "dir:cmd", "dir:internal/x"])
        XCTAssertEqual(chapters.map(\.title), ["(root)", "cmd", "internal/x"])
        XCTAssertEqual(chapters[1].paths, ["cmd/a.go", "cmd/c.go"])
        XCTAssertTrue(chapters.allSatisfy { !$0.core })
    }

    func testTestJoinsItsSubjectAndComesFirst() {
        let chapters = ReviewChapters.mechanical([
            file("internal/x/b.go"), file("internal/x/b_test.go"),
            file("WatchtowerDesktop/Sources/M/Foo.swift"), file("WatchtowerDesktop/Tests/FooTests.swift")
        ])
        let byKey = Dictionary(uniqueKeysWithValues: chapters.map { ($0.key, $0.paths) })
        XCTAssertEqual(byKey["dir:internal/x"], ["internal/x/b_test.go", "internal/x/b.go"])
        XCTAssertEqual(
            byKey["dir:WatchtowerDesktop/Sources/M"],
            ["WatchtowerDesktop/Tests/FooTests.swift", "WatchtowerDesktop/Sources/M/Foo.swift"]
        )
        XCTAssertNil(byKey["dir:WatchtowerDesktop/Tests"])
    }

    func testTestWithTwoPossibleSubjectsStaysInItsDirectory() {
        let chapters = ReviewChapters.mechanical([
            file("a/Foo.swift"), file("b/Foo.swift"), file("Tests/FooTests.swift")
        ])
        let byKey = Dictionary(uniqueKeysWithValues: chapters.map { ($0.key, $0.paths) })
        XCTAssertEqual(byKey["dir:Tests"], ["Tests/FooTests.swift"])
        XCTAssertEqual(byKey["dir:a"], ["a/Foo.swift"])
    }

    func testSplitsOverCapAndKeepsBigFileWhole() {
        let many = (0..<30).map { file(String(format: "pkg/f%02d.go", $0), add: 20) }
        let chapters = ReviewChapters.mechanical(many)
        XCTAssertEqual(chapters.first?.key, "dir:pkg")
        XCTAssertEqual(chapters[1].key, "dir:pkg#2")
        XCTAssertEqual(chapters.map(\.title).prefix(2), ["pkg", "pkg (2)"])
        XCTAssertTrue(chapters.allSatisfy { $0.changedLines <= ReviewChapters.maxChangedLines })
        XCTAssertEqual(chapters.reduce(0) { $0 + $1.changedLines }, 600)

        let big = ReviewChapters.mechanical([file("big/x.go", add: 1000)])
        XCTAssertEqual(big.count, 1)
        XCTAssertEqual(big[0].changedLines, 1000)

        let unit = ReviewChapters.mechanical([file("u/a.go", add: 200), file("u/a_test.go", add: 300)])
        XCTAssertEqual(unit.count, 1)
        XCTAssertEqual(unit[0].changedLines, 500)
    }

    func testCollapsedFilesGoLast() {
        let chapters = ReviewChapters.mechanical([
            file("go.sum", add: 500, collapsed: "lockfile"), file("a/x.go"), file("gen/y.pb.go", add: 900, collapsed: "generated")
        ])
        XCTAssertEqual(chapters.last?.key, "collapsed")
        XCTAssertEqual(chapters.last?.title, "Generated and lock files")
        XCTAssertEqual(chapters.last?.changedLines, 0)
        XCTAssertEqual(chapters.last?.paths, ["go.sum", "gen/y.pb.go"])
        XCTAssertEqual(chapters.count, 2)
    }

    func testIsTest() {
        for path in ["x_test.go", "FooTests.swift", "FooTest.kt", "a.test.ts", "a.spec.js", "test_a.py", "Tests/Support/Helper.swift"] {
            XCTAssertTrue(ReviewChapters.isTest(path), path)
        }
        for path in ["contest.go", "attestation.swift"] {
            XCTAssertFalse(ReviewChapters.isTest(path), path)
        }
    }

    func testDoneWhenEveryFileViewed() {
        let chapter = ReviewChapter(key: "dir:a", title: "a", paths: ["a/x", "a/y"], changedLines: 2, core: false)
        XCTAssertFalse(ReviewChapters.done(chapter) { $0 == "a/x" })
        XCTAssertTrue(ReviewChapters.done(chapter) { _ in true })
    }

    func testTestPairsWithSubjectInItsOwnDirectoryFirst() {
        let chapters = ReviewChapters.mechanical([
            file("cmd/x.go"), file("cmd/x_test.go"), file("pkg/x.go"), file("pkg/x_test.go")
        ])
        let byKey = Dictionary(uniqueKeysWithValues: chapters.map { ($0.key, $0.paths) })
        XCTAssertEqual(byKey["dir:cmd"], ["cmd/x_test.go", "cmd/x.go"])
        XCTAssertEqual(byKey["dir:pkg"], ["pkg/x_test.go", "pkg/x.go"])
    }

    func testProgressIgnoresCollapsedFiles() {
        let files = [file("a/x", add: 10), file("go.sum", add: 500, collapsed: "lock")]
        let progress = ReviewProgress.make(files: files, chapters: []) { _ in true }
        XCTAssertEqual(progress.totalLines, 10)
        XCTAssertEqual(progress.viewedLines, 10)
    }

    // MARK: chapter sources

    private func spec(_ title: String, _ paths: [String], core: Bool = false, lenses: [String]? = nil) -> ReviewChapterSpec {
        ReviewChapterSpec(title: title, paths: paths, core: core, lenses: lenses)
    }

    private func lens(_ id: String, builtin: Bool) -> ReviewLens {
        ReviewLens(id: id, name: id, builtin: builtin, items: [])
    }

    func testAgentChaptersWinOverAI() {
        let files = [file("a/x.go"), file("b/y.go")]
        let out = ReviewChapters.resolve(files, agent: [spec("A", ["a/x.go"])], ai: [spec("B", ["b/y.go"])])
        XCTAssertEqual(out.first?.key, "agent:1")
        XCTAssertEqual(out.first?.source, .agent)
        XCTAssertEqual(out.map(\.key), ["agent:1", "dir:b"])
    }

    func testAIChaptersWhenNoAgentChapters() {
        let out = ReviewChapters.resolve([file("a/x.go"), file("b/y.go")], agent: [], ai: [
            spec("One", ["a/x.go"], lenses: ["tests"]), spec("Two", ["b/y.go"])
        ])
        XCTAssertEqual(out.map(\.key), ["ai:1", "ai:2"])
        XCTAssertEqual(out[0].lenses, ["tests"])
        XCTAssertEqual(out[0].source, .ai)
    }

    func testUnknownPathsDroppedAndEmptyChapterSkipped() {
        let out = ReviewChapters.resolve([file("a/x.go"), file("a/x.go")], agent: [], ai: [
            spec("Ghost", ["nope.go"]), spec("Real", ["nope.go", "a/x.go"]), spec("Dup", ["a/x.go"])
        ])
        XCTAssertEqual(out.map(\.key), ["ai:2"])
        XCTAssertEqual(out[0].paths, ["a/x.go"])
        XCTAssertEqual(out[0].changedLines, 10)
    }

    func testLeftoverFilesGoToMechanicalChaptersAfter() {
        let out = ReviewChapters.resolve([file("a/x.go"), file("b/y.go")], agent: [spec("A", ["a/x.go"])], ai: [])
        XCTAssertEqual(out.map(\.key), ["agent:1", "dir:b"])
        XCTAssertEqual(out[1].source, .mechanical)
    }

    func testCoreFirstAndTestsFirstInside() {
        let files = [file("a/x.go"), file("a/x_test.go"), file("b/y.go")]
        let out = ReviewChapters.resolve(files, agent: [], ai: [
            spec("Later", ["b/y.go"]), spec("Main", ["a/x.go", "a/x_test.go"], core: true)
        ])
        XCTAssertEqual(out.map(\.title), ["Main", "Later"])
        XCTAssertEqual(out[0].paths, ["a/x_test.go", "a/x.go"])
    }

    func testAllSourcesEmptyIsMechanical() {
        let files = [file("a/x.go"), file("b/y.go", collapsed: "lock")]
        XCTAssertEqual(ReviewChapters.resolve(files, agent: [], ai: []), ReviewChapters.mechanical(files))
        XCTAssertEqual(ReviewChapters.resolve(files, agent: [], ai: [spec("G", ["zzz"])]), ReviewChapters.mechanical(files))
    }

    func testCollapsedFilesInChosenChapterCostNoReadingTime() {
        let files = [file("a/x.go", add: 10, del: 2), file("a/go.sum", add: 500, collapsed: "lock")]
        let out = ReviewChapters.resolve(files, agent: [spec("A", ["a/x.go", "a/go.sum"])], ai: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].paths, ["a/x.go", "a/go.sum"])
        XCTAssertEqual(out[0].changedLines, 12)
    }

    func testLensesForAIChapterKeepHouseRulesAndOwnerLenses() {
        let all = [
            lens("correctness", builtin: true), lens("tests", builtin: true),
            lens("house_rules", builtin: true), lens("docs", builtin: false)
        ]
        let ai = ReviewChapter(key: "ai:1", title: "t", paths: [], changedLines: 0, core: false, source: .ai, lenses: ["tests"])
        XCTAssertEqual(ReviewChapters.lenses(for: ai, all: all).map(\.id), ["tests", "house_rules", "docs"])
    }

    func testLensesForMechanicalAreAll() {
        let all = [lens("correctness", builtin: true), lens("tests", builtin: true)]
        let agent = ReviewChapter(key: "agent:1", title: "t", paths: [], changedLines: 0, core: false, source: .agent, lenses: ["tests"])
        let mech = ReviewChapter(key: "dir:a", title: "t", paths: [], changedLines: 0, core: false)
        XCTAssertEqual(ReviewChapters.lenses(for: agent, all: all), all)
        XCTAssertEqual(ReviewChapters.lenses(for: mech, all: all), all)
    }

    func testEstimateMinutes() {
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 0), 0)
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 1), 1)
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 400), 60)
        XCTAssertEqual(ReviewChapters.estimateMinutes(changedLines: 1000), 150)
    }
}
