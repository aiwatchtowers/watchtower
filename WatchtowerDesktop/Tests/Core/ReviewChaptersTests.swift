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
}
