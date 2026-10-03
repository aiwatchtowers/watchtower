import XCTest
@testable import WatchtowerCore

/// One workbench's in-memory index (spec §7): files and symbols applied
/// from the CLI's stream, a full run pruning what it no longer lists, and
/// Open Quickly's query over both.
@MainActor
final class WorkbenchCodeIndexTests: XCTestCase {
    private func symbol(_ name: String, _ kind: CodeSymbolKind, _ path: String, line: Int = 1, outline: Bool = false) -> CodeSymbol {
        CodeSymbol(name: name, kind: kind, path: path, line: line, col: 1, endLine: line, outline: outline)
    }

    private func file(_ path: String, lang: String = "swift", _ symbols: [CodeSymbol] = []) -> CodeIndexLine {
        .file(CodeIndexFileResult(file: path, lang: lang, symbols: symbols))
    }

    func testAppliedFilesAndSymbols() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([
            file("a.swift", [symbol("Buffer", .class, "a.swift", line: 1), symbol("save", .method, "a.swift", line: 9)]),
            file("b.swift", [symbol("save", .function, "b.swift", line: 3)]),
            file("notes.txt", lang: "")
        ], from: .fullRun)
        XCTAssertEqual(index.files, ["a.swift", "b.swift", "notes.txt"])
        XCTAssertEqual(index.symbols(named: "save").map(\.path).sorted(), ["a.swift", "b.swift"])
        XCTAssertEqual(index.symbols(named: "Save"), [], "definition lookup is case-sensitive")
        XCTAssertEqual(index.symbols(in: "a.swift").map(\.name), ["Buffer", "save"])
    }

    /// Ruling R31: go to definition searches text only in a file whose
    /// language the index does not read.
    func testTheLanguageOfAFileAsTheCLIReportedIt() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([file("a.swift"), file("run.pl", lang: "")], from: .fullRun)
        XCTAssertEqual(index.language(of: "a.swift"), "swift")
        XCTAssertEqual(index.language(of: "run.pl"), "", "a workbench file in a language the CLI does not index")
        XCTAssertNil(index.language(of: "other.go"), "not (yet) in the index")
        index.applyIndexLines([file("run.pl", lang: "perl")], from: .update)
        XCTAssertEqual(index.language(of: "run.pl"), "perl", "an update replaces it")
        index.applyIndexLines([.deleted("run.pl")], from: .update)
        XCTAssertNil(index.language(of: "run.pl"))
    }

    /// Ruling R32: a file whose language holds no code definitions
    /// (`"defs":false`) reads as unsupported for navigation, its language
    /// as reported stays.
    func testTheDefinitionLanguageOfMarkupAndConfigIsUnsupported() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([
            file("a.swift"), file("run.pl", lang: ""),
            .file(CodeIndexFileResult(file: "README.md", lang: "markdown", symbols: [], holdsDefinitions: false))
        ], from: .fullRun)
        XCTAssertEqual(index.definitionLanguage(of: "a.swift"), "swift")
        XCTAssertEqual(index.definitionLanguage(of: "run.pl"), "")
        XCTAssertEqual(index.definitionLanguage(of: "README.md"), "", "markup: text search, like an unsupported language")
        XCTAssertEqual(index.language(of: "README.md"), "markdown")
        XCTAssertNil(index.definitionLanguage(of: "other.go"), "not (yet) in the index")
        index.applyIndexLines([.file(CodeIndexFileResult(file: "README.md", lang: "markdown", symbols: []))], from: .update)
        XCTAssertEqual(index.definitionLanguage(of: "README.md"), "markdown", "an update replaces the flag")
    }

    func testDeletedRemovesTheFileAndItsSubtree() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([
            file("lib/a.swift", [symbol("A", .struct, "lib/a.swift")]),
            file("lib/sub/b.swift", [symbol("B", .struct, "lib/sub/b.swift")]),
            file("library.swift", [symbol("L", .struct, "library.swift")])
        ], from: .fullRun)
        index.applyIndexLines([.deleted("lib")], from: .update)
        XCTAssertEqual(index.files, ["library.swift"])
        XCTAssertEqual(index.symbols(named: "A"), [])
        XCTAssertEqual(index.symbols(in: "lib/sub/b.swift"), [])
        index.applyIndexLines([.deleted("library.swift")], from: .update)
        XCTAssertEqual(index.files, [])
        XCTAssertEqual(index.symbols(named: "L"), [])
    }

    func testAnUpdateReplacesSymbolsAddsWorkbenchFilesAndDropsSkippedOnes() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([file("a.swift", [symbol("Old", .class, "a.swift")]), file("dist/old.js", lang: "javascript")], from: .fullRun)
        index.applyIndexLines([
            file("a.swift", [symbol("New", .class, "a.swift")]),
            file("notes.txt", lang: ""),
            .file(CodeIndexFileResult(file: "dist/x.js", lang: "", symbols: [], skipped: true)),
            .file(CodeIndexFileResult(file: "dist/old.js", lang: "", symbols: [], skipped: true))
        ], from: .update)
        XCTAssertEqual(index.symbols(named: "Old"), [])
        XCTAssertEqual(index.symbols(named: "New").count, 1)
        XCTAssertEqual(index.files, ["a.swift", "notes.txt"], "a new unsupported file is listed; skipped paths are not, and leave if listed")
    }

    func testAFullRunPrunesWhatItNoLongerLists() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([file("a.swift"), file("b.swift", [symbol("B", .class, "b.swift")])], from: .fullRun)
        index.beginFullRun()
        index.applyIndexLines([file("a.swift")], from: .fullRun)
        XCTAssertEqual(index.files, ["a.swift", "b.swift"], "queries answer from the current index during the run")
        index.finishFullRun()
        XCTAssertEqual(index.files, ["a.swift"])
        XCTAssertEqual(index.symbols(named: "B"), [])
    }

    func testQueryRanksFilesAndSymbols() throws {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines([
            file("ViewModels/CodeFileBuffer.swift", [symbol("CodeFileBuffer", .class, "ViewModels/CodeFileBuffer.swift")]),
            file("Models/ConfigBuffer.swift", [symbol("ConfigBuffer", .class, "Models/ConfigBuffer.swift")]),
            file("README.md", lang: "markdown", [symbol("CodeFileBuffer notes", .module, "README.md", outline: true)])
        ], from: .fullRun)
        let files = index.query("cfbuf", scope: .files, boosts: .none)
        XCTAssertEqual(files.map(\.title), ["CodeFileBuffer.swift", "ConfigBuffer.swift"])
        XCTAssertEqual(files.first?.titleMatches, [0, 4, 8, 9, 10])
        let symbols = index.query("cfbuf", scope: .symbols, boosts: .none)
        XCTAssertEqual(symbols.map(\.title), ["CodeFileBuffer", "ConfigBuffer"], "outline entries stay out of Symbols")
        let path = try XCTUnwrap(index.query("vm/cfb", scope: .files, boosts: .none).first)
        XCTAssertEqual(path.item, .file(path: "ViewModels/CodeFileBuffer.swift"))
        XCTAssertEqual(path.pathMatches, [0, 4, 10, 11, 15, 19])
        XCTAssertEqual(path.titleMatches, [0, 4, 8])
        XCTAssertEqual(index.query("cfbuf", scope: .text, boosts: .none), [], "text answers come from code search")
        XCTAssertEqual(index.query("cfbuf", scope: .all, boosts: .none).count, 4)
    }

    func testEmptyQueryListsFilesInBoostOrder() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines(["a.go", "b.go", "c.go", "d.go"].map { file($0, lang: "go") }, from: .fullRun)
        let boosts = CodeRankingBoosts(openTabs: ["c.go"], recent: ["d.go"], gitModified: ["b.go"])
        XCTAssertEqual(index.query("", scope: .all, boosts: boosts).map(\.title), ["c.go", "d.go", "b.go", "a.go"])
        XCTAssertEqual(index.query("  ", scope: .symbols, boosts: boosts), [])
    }

    /// Spec §7 target: ≤ 50 ms per keystroke over a 3 000-file /
    /// 30 000-symbol index (a debug build, so the release app has headroom).
    func testQueryLatencyOnASyntheticRepository() {
        let index = WorkbenchCodeIndex()
        index.applyIndexLines(Self.syntheticRepository(files: 3000, symbolsPerFile: 10), from: .fullRun)
        XCTAssertEqual(index.files.count, 3000)
        let queries = [
            "c", "cf", "cfb", "cfbuf", "save", "saveNow", "vm/cfb", "src/mod", "Handler", "hndlr",
            "zz", "x", "parse", "ParseConfig", "pkg/svc/h", "renderView", "rv", "conf", "e", "store.swift"
        ]
        let boosts = CodeRankingBoosts(openTabs: ["Sources/Module7/Feature3/File7.swift"], recent: [], gitModified: [])
        var worst: Duration = .zero
        measure {
            for query in queries {
                let start = ContinuousClock.now
                _ = index.query(query, scope: .all, boosts: boosts)
                worst = max(worst, ContinuousClock.now - start)

            }
        }
        XCTAssertLessThanOrEqual(worst, .milliseconds(50), "slowest query took \(worst)")
    }

    private static func syntheticRepository(files: Int, symbolsPerFile: Int) -> [CodeIndexLine] {
        let words = ["Code", "File", "Buffer", "Config", "Parse", "Render", "View", "Store", "Handler", "Save", "Now", "Service"]
        let kinds: [CodeSymbolKind] = [.class, .method, .function, .field, .const, .struct]
        return (0 ..< files).map { n in
            let path = "Sources/Module\(n % 40)/Feature\(n % 7)/\(words[n % words.count])\(words[(n / 12) % words.count])\(n).swift"
            let symbols = (0 ..< symbolsPerFile).map { k in
                let name = words[(n + k) % words.count] + words[(n * 7 + k) % words.count] + "\(k)"
                return CodeSymbol(name: name, kind: kinds[k % kinds.count], path: path, line: k * 10 + 1, col: 5, endLine: k * 10 + 8)
            }
            return .file(CodeIndexFileResult(file: path, lang: "swift", symbols: symbols))
        }
    }
}
