import XCTest
@testable import WatchtowerCore

final class CodeTabsTests: XCTestCase {
    func testPreviewOpenReplacesThePreviewTabInPlace() {
        var tabs = CodeTabs()
        tabs.open("a.go", preview: false)
        tabs.open("b.go", preview: true)
        tabs.open("c.go", preview: true)
        XCTAssertEqual(tabs.paths, ["a.go", "c.go"])
        XCTAssertEqual(tabs.active, "c.go")
        XCTAssertEqual(tabs.tabs.last?.isPreview, true)
    }

    func testKeptOpenOfThePreviewTabPinsIt() {
        var tabs = CodeTabs()
        tabs.open("a.go", preview: true)
        tabs.open("a.go", preview: false)
        tabs.open("b.go", preview: true)
        XCTAssertEqual(tabs.paths, ["a.go", "b.go"])
        XCTAssertEqual(tabs.tabs.map(\.isPreview), [false, true])
    }

    func testPreviewOpenOfAnOpenTabOnlyActivatesIt() {
        var tabs = CodeTabs()
        tabs.open("a.go", preview: false)
        tabs.open("b.go", preview: false)
        tabs.open("a.go", preview: true)
        XCTAssertEqual(tabs.active, "a.go")
        XCTAssertEqual(tabs.tabs.map(\.isPreview), [false, false])
    }

    func testPinKeepsThePreviewTab() {
        var tabs = CodeTabs()
        tabs.open("a.go", preview: true)
        tabs.pin("a.go")
        tabs.open("b.go", preview: true)
        XCTAssertEqual(tabs.paths, ["a.go", "b.go"])
    }

    func testNewTabGoesAfterTheActiveOne() {
        var tabs = CodeTabs()
        tabs.open("a.go", preview: false)
        tabs.open("b.go", preview: false)
        tabs.activate("a.go")
        tabs.open("c.go", preview: false)
        XCTAssertEqual(tabs.paths, ["a.go", "c.go", "b.go"])
    }

    func testClosingTheActiveTabActivatesRightThenLeftNeighbour() {
        var tabs = CodeTabs()
        ["a", "b", "c"].forEach { tabs.open($0, preview: false) }
        tabs.activate("b")
        tabs.close("b")
        XCTAssertEqual(tabs.active, "c")
        tabs.close("c")
        XCTAssertEqual(tabs.active, "a")
        tabs.close("a")
        XCTAssertNil(tabs.active)
        XCTAssertTrue(tabs.tabs.isEmpty)
    }

    func testClosingAnInactiveTabKeepsTheActiveOne() {
        var tabs = CodeTabs()
        ["a", "b", "c"].forEach { tabs.open($0, preview: false) }
        tabs.close("a")
        XCTAssertEqual(tabs.active, "c")
    }

    func testRenameFollowsAFileAndEveryTabUnderAFolder() {
        var tabs = CodeTabs()
        ["a/x.go", "a/b/y.go", "ab/z.go"].forEach { tabs.open($0, preview: false) }
        tabs.open("a/p.go", preview: true)
        tabs.rename("a", to: "c")
        XCTAssertEqual(tabs.paths, ["c/x.go", "c/b/y.go", "ab/z.go", "c/p.go"])
        XCTAssertEqual(tabs.active, "c/p.go")
        XCTAssertEqual(tabs.tabs.last?.isPreview, true)
        tabs.rename("ab/z.go", to: "ab/w.go")
        XCTAssertEqual(tabs.paths[2], "ab/w.go")
    }

    func testCloseTreeClosesAFolderButNotItsNamesakes() {
        var tabs = CodeTabs()
        ["a/x.go", "a/b/y.go", "ab/z.go"].forEach { tabs.open($0, preview: false) }
        tabs.closeTree("a")
        XCTAssertEqual(tabs.paths, ["ab/z.go"])
        XCTAssertEqual(tabs.active, "ab/z.go")
    }

    func testMoveBeforeATargetOrToTheEnd() {
        var tabs = CodeTabs()
        ["a", "b", "c"].forEach { tabs.open($0, preview: false) }
        tabs.move("c", before: "a")
        XCTAssertEqual(tabs.paths, ["c", "a", "b"])
        tabs.move("c", before: nil)
        XCTAssertEqual(tabs.paths, ["a", "b", "c"])
        tabs.move("a", before: "a")
        XCTAssertEqual(tabs.paths, ["a", "b", "c"])
    }

    func testPruneDropsMissingFiles() {
        var tabs = CodeTabs()
        ["a", "b"].forEach { tabs.open($0, preview: false) }
        tabs.prune { $0 == "a" }
        XCTAssertEqual(tabs.paths, ["a"])
        XCTAssertEqual(tabs.active, "a")
    }

    func testSubtitlesTellSameNamesApartByTheShortestDifferingFolders() {
        var tabs = CodeTabs()
        ["cmd/main.go", "internal/sync/main.go", "x/sync/main.go", "main.go", "Makefile"].forEach {
            tabs.open($0, preview: false)
        }
        let subtitles = tabs.subtitles
        XCTAssertEqual(subtitles["cmd/main.go"], "cmd")
        XCTAssertEqual(subtitles["internal/sync/main.go"], "internal/sync")
        XCTAssertEqual(subtitles["x/sync/main.go"], "x/sync")
        XCTAssertEqual(subtitles["main.go"], "./")
        XCTAssertNil(subtitles["Makefile"])
    }

    func testRoundTripsAsJSON() throws {
        var tabs = CodeTabs()
        tabs.open("a.go", preview: false)
        tabs.open("b.go", preview: true)
        let decoded = try JSONDecoder().decode(CodeTabs.self, from: JSONEncoder().encode(tabs))
        XCTAssertEqual(decoded, tabs)
    }
}
