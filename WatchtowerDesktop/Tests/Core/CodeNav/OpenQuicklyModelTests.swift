import XCTest
@testable import WatchtowerCore

/// Open Quickly's sections, caps and selection (spec §8.1): All = Best match
/// + Symbols (8) + Files (8) + Text (20, then "more…") and a last "Ask AI"
/// row; a scope switch keeps the query; ↑/↓ stop at the ends.
final class OpenQuicklyModelTests: XCTestCase {
    private func file(_ path: String, score: Int = 10) -> CodeQuickResult {
        CodeQuickResult(item: .file(path: path), score: score, titleMatches: [], pathMatches: [])
    }

    private func symbol(_ name: String, score: Int = 10, kind: CodeSymbolKind = .function) -> CodeQuickResult {
        let symbol = CodeSymbol(name: name, kind: kind, path: "src/\(name).swift", line: 3, col: 6, endLine: 9)
        return CodeQuickResult(item: .symbol(symbol), score: score, titleMatches: [], pathMatches: [])
    }

    private func textMatch(_ n: Int) -> CodeSearchMatch {
        CodeSearchMatch(path: "t\(n).go", line: n, col: 2, text: "q here", textCol: 1, before: [], after: [])
    }

    private func filledAllScope(query: String = "q") -> OpenQuicklyModel {
        var model = OpenQuicklyModel()
        model.setQuery(query)
        model.setIndexResults(
            files: (0 ..< 12).map { file("f\($0).go", score: 50 - $0) },
            symbols: (0 ..< 12).map { symbol("s\($0)", score: 60 - $0) }
        )
        model.appendTextMatches((1 ... 25).map(textMatch))
        return model
    }

    func testAllScopeSectionsAndCaps() {
        let model = filledAllScope()
        XCTAssertEqual(model.sections.map(\.kind), [.bestMatch, .symbols, .files, .text, .askAI])
        let byKind = Dictionary(uniqueKeysWithValues: model.sections.map { ($0.kind, $0.rows) })
        XCTAssertEqual(byKind[.bestMatch]?.map(\.id), [symbol("s0").id], "the best of files and symbols")
        XCTAssertEqual(byKind[.symbols]?.count, 8)
        XCTAssertFalse(byKind[.symbols]?.contains { $0.id == symbol("s0").id } ?? true, "the best match is not repeated")
        XCTAssertEqual(byKind[.files]?.count, 8)
        XCTAssertEqual(byKind[.files]?.first?.id, file("f0.go").id)
        let text = byKind[.text] ?? []
        XCTAssertEqual(text.count, 21, "20 matches and the more… row")
        XCTAssertEqual(text.last, .moreText(hidden: 5))
        XCTAssertEqual(model.rows.last, .askAI(query: "q"))
        XCTAssertEqual(OpenQuicklySectionKind.bestMatch.title, "Best match")
        XCTAssertEqual(OpenQuicklyRow.askAI(query: "q").label, "✦ Ask AI: \u{201C}q\u{201D}")
    }

    func testABetterFileIsTheBestMatch() {
        var model = OpenQuicklyModel()
        model.setQuery("cfb")
        model.setIndexResults(files: [file("CodeFileBuffer.swift", score: 90)], symbols: [symbol("cfb", score: 20)])
        XCTAssertEqual(model.sections.first?.rows.map(\.id), [file("CodeFileBuffer.swift").id])
        XCTAssertEqual(model.sections.map(\.kind), [.bestMatch, .symbols, .askAI], "an empty Files section is left out")
    }

    func testTwentyTextMatchesOrFewerHaveNoMoreRow() {
        var model = OpenQuicklyModel()
        model.setQuery("q")
        model.appendTextMatches((1 ... 20).map(textMatch))
        XCTAssertFalse(model.rows.contains(.moreText(hidden: 0)))
        XCTAssertEqual(model.sections.first { $0.kind == .text }?.rows.count, 20)
    }

    func testMoreSwitchesToTheTextScopeKeepingTheQuery() {
        var model = filledAllScope()
        model.select(OpenQuicklyRow.moreText(hidden: 5).id)
        XCTAssertEqual(model.activateSelection(option: false, command: false), .none)
        XCTAssertEqual(model.scope, .text)
        XCTAssertEqual(model.query, "q")
        XCTAssertEqual(model.sections.map(\.kind), [.text])
        XCTAssertEqual(model.rows.count, 25, "the Text scope is not capped")
        XCTAssertEqual(model.selectedRow?.id, OpenQuicklyRow.text(textMatch(1)).id)
    }

    func testSwitchingScopeKeepsTheQueryAndResetsTheSelection() {
        var model = filledAllScope(query: "abc")
        model.move(.down)
        model.setScope(.files)
        XCTAssertEqual(model.query, "abc")
        XCTAssertEqual(model.scope, .files)
        model.setIndexResults(files: [file("a.go"), file("b.go")], symbols: [])
        XCTAssertEqual(model.sections.map(\.kind), [.files])
        XCTAssertEqual(model.selectedRow?.id, file("a.go").id)
        model.setScope(.all)
        XCTAssertEqual(model.query, "abc")
    }

    func testArrowsStopAtTheEnds() {
        var model = OpenQuicklyModel()
        model.setQuery("q")
        model.setIndexResults(files: [file("a.go", score: 30), file("b.go", score: 20)], symbols: [])
        // Best match a.go, Files b.go, Ask AI.
        XCTAssertEqual(model.selectedRow?.id, file("a.go").id)
        model.move(.up)
        XCTAssertEqual(model.selectedRow?.id, file("a.go").id, "no wrap at the top")
        model.move(.down)
        model.move(.down)
        XCTAssertEqual(model.selectedRow, .askAI(query: "q"))
        model.move(.down)
        XCTAssertEqual(model.selectedRow, .askAI(query: "q"), "no wrap at the bottom")
    }

    func testTypingSelectsTheFirstRowAndStreamingKeepsTheSelection() {
        var model = filledAllScope()
        model.move(.down)
        model.move(.down)
        let picked = model.selectedRow?.id
        model.appendTextMatches([textMatch(30)])
        XCTAssertEqual(model.selectedRow?.id, picked, "a match arriving does not move the selection")
        model.setQuery("qq")
        XCTAssertTrue(model.textMatches.isEmpty, "a new query drops the old text matches")
        XCTAssertEqual(model.selectedRow, .askAI(query: "qq"), "nothing else yet: the only row")
        model.setIndexResults(files: [file("x.go")], symbols: [])
        XCTAssertEqual(model.selectedRow?.id, file("x.go").id)
    }

    func testEmptyQueryListsFilesWithoutAskAI() {
        var model = OpenQuicklyModel()
        model.setIndexResults(files: (0 ..< 10).map { file("f\($0).go") }, symbols: [])
        XCTAssertEqual(model.sections.map(\.kind), [.files])
        XCTAssertEqual(model.rows.count, 8)
        model.setScope(.files)
        XCTAssertEqual(model.rows.count, 10)
    }

    func testReturnOptionReturnAndCommandReturn() {
        var model = OpenQuicklyModel()
        model.setQuery("s")
        model.setIndexResults(files: [], symbols: [symbol("save", score: 40)])
        let target = OpenQuicklyTarget(path: "src/save.swift", line: 3, col: 6)
        XCTAssertEqual(model.activateSelection(option: false, command: false), .open(target, beside: false))
        XCTAssertEqual(model.activateSelection(option: true, command: false), .open(target, beside: true))
        XCTAssertEqual(model.activateSelection(option: false, command: true), .askAI("s"))
        XCTAssertEqual(model.activateSelection(option: true, command: true), .handToClaude("s"), "⌥⌘↩ delegates, not asks")
        model.select(OpenQuicklyRow.askAI(query: "s").id)
        XCTAssertEqual(model.activateSelection(option: false, command: false), .askAI("s"))

        model.select(file("x").id)
        model.setQuery("")
        XCTAssertEqual(model.activateSelection(option: false, command: true), .none, "nothing to ask")
        XCTAssertEqual(model.activateSelection(option: true, command: true), .none, "nothing to hand over")
    }

    func testTargets() {
        XCTAssertEqual(OpenQuicklyRow.match(file("a/b.go")).target, OpenQuicklyTarget(path: "a/b.go", line: nil, col: nil))
        XCTAssertEqual(OpenQuicklyRow.text(textMatch(7)).target, OpenQuicklyTarget(path: "t7.go", line: 7, col: 2))
        XCTAssertNil(OpenQuicklyRow.askAI(query: "q").target)
        XCTAssertNil(OpenQuicklyRow.moreText(hidden: 1).target)
    }

    func testSpaceTogglesQuickLookOnlyWhileNavigating() {
        var model = filledAllScope()
        XCTAssertEqual(model.spaceAction(quickLookShown: false), .insertSpace, "typing: a space is part of the query")
        model.move(.down)
        let path = model.selectedRow?.target?.path ?? ""
        XCTAssertEqual(model.spaceAction(quickLookShown: false), .toggleQuickLook(path), "a symbol row previews its file")
        model.setQuery("q ")
        model.setIndexResults(files: [file("a.go")], symbols: [])
        XCTAssertEqual(model.spaceAction(quickLookShown: false), .insertSpace)
        XCTAssertEqual(model.spaceAction(quickLookShown: true), .toggleQuickLook("a.go"), "Space closes it")

        model.select(OpenQuicklyRow.askAI(query: "q ").id)
        model.move(.down)
        XCTAssertEqual(model.spaceAction(quickLookShown: false), .insertSpace, "the Ask AI row has no file")
    }

    func testTextOutcome() {
        var model = OpenQuicklyModel()
        model.setQuery("q")
        XCTAssertEqual(model.textStatus, .searching)
        model.finishText(.finished(truncated: true))
        XCTAssertEqual(model.textStatus, .finished(truncated: true))
        model.setQuery("w")
        XCTAssertEqual(model.textStatus, .searching)
        model.finishText(.failed("boom"))
        XCTAssertEqual(model.textStatus, .failed("boom"))
        model.setQuery("")
        XCTAssertEqual(model.textStatus, .idle)
    }

    /// Outline entries (Markdown headings, config keys) stay out of the
    /// Symbols scope (spec §6.1).
    @MainActor
    func testOutlineSymbolsAreNotInTheSymbolsScope() {
        let index = WorkbenchCodeIndex()
        let heading = CodeSymbol(name: "Install", kind: .module, path: "README.md", line: 1, col: 3, endLine: 9, outline: true)
        let function = CodeSymbol(name: "install", kind: .function, path: "a.go", line: 2, col: 6, endLine: 4)
        index.applyIndexLines([
            .file(CodeIndexFileResult(file: "README.md", lang: "markdown", symbols: [heading], skipped: false)),
            .file(CodeIndexFileResult(file: "a.go", lang: "go", symbols: [function], skipped: false))
        ], from: .update)
        let symbols = index.query("install", scope: .symbols, boosts: .none)
        XCTAssertEqual(symbols.map(\.item), [.symbol(function)])
    }
}
