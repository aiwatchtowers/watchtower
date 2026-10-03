import XCTest
@testable import WatchtowerCore

/// The Usages inspector's list (spec §8.3): matches of `code search --word
/// --case` grouped per file in the order the files arrive, a header
/// "Usages — name · N", rows with the name cut out for bold, and a
/// collapsed group that stays collapsed while more matches stream in.
final class UsagesModelTests: XCTestCase {
    private func hit(_ path: String, _ line: Int, _ text: String, textCol: Int, col: Int? = nil) -> CodeSearchMatch {
        CodeSearchMatch(path: path, line: line, col: col ?? textCol, text: text, textCol: textCol, before: [], after: [])
    }

    func testANewModelIsEmptyAndSearching() {
        let model = UsagesModel(word: "save")
        XCTAssertEqual(model.word, "save")
        XCTAssertEqual(model.groups, [])
        XCTAssertEqual(model.count, 0)
        XCTAssertEqual(model.status, .searching)
        XCTAssertEqual(model.header, "Usages — save · 0")
    }

    func testMatchesGroupPerFileInArrivalOrderAndCount() {
        var model = UsagesModel(word: "save")
        model.append(hit("z/last.swift", 4, "save()", textCol: 1))
        model.append(hit("a/first.swift", 9, "x.save()", textCol: 3))
        model.append(hit("z/last.swift", 2, "func save() {}", textCol: 6))
        model.append(hit("m/mid.go", 1, "save", textCol: 1))
        XCTAssertEqual(model.groups.map(\.path), ["z/last.swift", "a/first.swift", "m/mid.go"], "files in the order they arrived")
        XCTAssertEqual(model.groups[0].rows.map(\.line), [4, 2], "rows in the order they arrived")
        XCTAssertEqual(model.groups.map(\.rows.count), [2, 1, 1])
        XCTAssertEqual(model.count, 4)
        XCTAssertEqual(model.header, "Usages — save · 4")
    }

    func testTheRowCutsOutTheNameAtItsUTF16ColumnAndDropsTheIndent() {
        var model = UsagesModel(word: "name")
        // Two emoji before the name: 4 UTF-16 units, so the name starts at unit 14.
        let text = "\t  s = \"\u{1F600}\u{1F600}\"; name()"
        let col = (text.components(separatedBy: "name").first?.utf16.count ?? 0) + 1
        model.append(hit("a.swift", 3, text, textCol: col, col: 40))
        let row = model.groups[0].rows[0]
        XCTAssertEqual(row.parts, UsageRow.Parts(before: "s = \"\u{1F600}\u{1F600}\"; ", name: "name", after: "()"))
        XCTAssertEqual(row.target, OpenQuicklyTarget(path: "a.swift", line: 3, col: 40), "the target is the full line's column")
    }

    func testAColumnOutsideTheTextShowsTheWholeLinePlain() {
        var model = UsagesModel(word: "name")
        model.append(hit("a.swift", 1, "  short", textCol: 50))
        model.append(hit("a.swift", 2, "nam", textCol: 1))
        XCTAssertEqual(model.groups[0].rows.map(\.parts), [
            UsageRow.Parts(before: "short", name: "", after: ""),
            UsageRow.Parts(before: "nam", name: "", after: "")
        ])
    }

    func testTheNameKeepsItsIndentWhenTheMatchIsInsideIt() {
        // Not a real word match, but a column inside the indent must not cut the name.
        var model = UsagesModel(word: "  x")
        model.append(hit("a.swift", 1, "  x = 1", textCol: 1))
        XCTAssertEqual(model.groups[0].rows[0].parts, UsageRow.Parts(before: "", name: "  x", after: " = 1"))
    }

    func testTheSameMatchTwiceIsKeptOnce() {
        var model = UsagesModel(word: "save")
        model.append(hit("a.swift", 1, "save", textCol: 1))
        model.append(hit("a.swift", 1, "save", textCol: 1))
        XCTAssertEqual(model.count, 1)
    }

    func testCollapsingAGroupSurvivesNewArrivals() {
        var model = UsagesModel(word: "save")
        model.append(hit("a.swift", 1, "save", textCol: 1))
        model.append(hit("b.swift", 1, "save", textCol: 1))
        model.setCollapsed(true, path: "a.swift")
        XCTAssertTrue(model.isCollapsed("a.swift"))
        model.append(hit("a.swift", 7, "save()", textCol: 1))
        model.append(hit("c.swift", 1, "save", textCol: 1))
        XCTAssertTrue(model.isCollapsed("a.swift"), "a match in the collapsed file leaves it collapsed")
        XCTAssertFalse(model.isCollapsed("b.swift"))
        XCTAssertFalse(model.isCollapsed("c.swift"), "a file arriving later starts expanded")
        XCTAssertEqual(model.groups[0].rows.count, 2, "the collapsed group still collects its rows")
        model.setCollapsed(false, path: "a.swift")
        XCTAssertFalse(model.isCollapsed("a.swift"))
    }

    func testTheEndOfTheSearch() {
        var finished = UsagesModel(word: "save")
        finished.finish(truncated: false)
        XCTAssertEqual(finished.status, .finished(truncated: false))
        XCTAssertEqual(finished.statusText, "No usages of save found.")

        var truncated = UsagesModel(word: "save")
        truncated.append(hit("a.swift", 1, "save", textCol: 1))
        truncated.append(hit("a.swift", 2, "save", textCol: 1))
        truncated.finish(truncated: true)
        XCTAssertEqual(truncated.statusText, "Showing the first 2 matches.")

        var done = UsagesModel(word: "save")
        done.append(hit("a.swift", 1, "save", textCol: 1))
        done.finish(truncated: false)
        XCTAssertNil(done.statusText, "a complete list needs no line under it")

        var failed = UsagesModel(word: "save")
        failed.fail("exit status 2")
        XCTAssertEqual(failed.status, .failed("exit status 2"))
        XCTAssertEqual(failed.statusText, "The search failed: exit status 2")

        var stopped = UsagesModel(word: "save")
        stopped.stop()
        XCTAssertEqual(stopped.statusText, "The search stopped before it finished.")
        XCTAssertEqual(UsagesModel(word: "save").statusText, "Searching…")
    }

    func testAMatchAfterTheEndIsDropped() {
        var model = UsagesModel(word: "save")
        model.stop()
        model.append(hit("a.swift", 1, "save", textCol: 1))
        XCTAssertEqual(model.count, 0)
        XCTAssertEqual(model.status, .stopped)
        model.finish(truncated: false)
        XCTAssertEqual(model.status, .stopped, "the first end stays")
    }
}
