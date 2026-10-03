import XCTest
@testable import WatchtowerCore

/// The jump bar above the editor (spec §8.4): folders › file › type ›
/// method at the cursor, from the index by line range; a muted note at the
/// end for a language the index does not read or an index that failed; and
/// the menus behind the segments.
final class JumpBarSegmentsTests: XCTestCase {
    private let path = "Sources/App/Store.swift"

    // Outer (1–40) holds Inner (3–20) holding save (5–9) and load (12–15);
    // Outer's own method (25–30); a top-level function (45–50).
    private lazy var outer = sym("Outer", .class, 1, 40)
    private lazy var inner = sym("Inner", .struct, 3, 20, container: "Outer")
    private lazy var save = sym("save", .method, 5, 9, container: "Inner")
    private lazy var load = sym("load", .method, 12, 15, container: "Inner")
    private lazy var count = sym("count", .field, 22, 22, container: "Outer")
    private lazy var flush = sym("flush", .method, 25, 30, container: "Outer")
    private lazy var helper = sym("helper", .function, 45, 50)
    private lazy var other = sym("Other", .enum, 52, 60)
    private lazy var all = [outer, inner, save, load, count, flush, helper, other]

    private func sym(
        _ name: String, _ kind: CodeSymbolKind, _ line: Int, _ end: Int, container: String = "", outline: Bool = false, file: String? = nil
    ) -> CodeSymbol {
        CodeSymbol(name: name, kind: kind, path: file ?? path, line: line, col: 1, endLine: end, container: container, outline: outline)
    }

    private func model(
        line: Int?, symbols: [CodeSymbol]? = nil, language: String? = "swift", state: CodeIndexState = .ready, file: String? = nil
    ) -> JumpBarModel {
        JumpBarModel(path: file ?? path, rootName: "acme", cursorLine: line, symbols: symbols ?? all, language: language, state: state)
    }

    private var folderAndFile: [JumpBarSegment] {
        [.folder(name: "acme", path: ""), .folder(name: "Sources", path: "Sources"),
         .folder(name: "App", path: "Sources/App"), .file(path: path)]
    }

    // MARK: Segments

    func testACursorInAMethodOfANestedTypeShowsFoldersFileOuterInnerMethod() {
        let bar = model(line: 7)
        XCTAssertEqual(bar.segments, folderAndFile + [.symbol(outer), .symbol(inner), .symbol(save)])
        XCTAssertNil(bar.status)
    }

    func testABlankLineBetweenMethodsShowsTheTypeLast() {
        XCTAssertEqual(model(line: 11).segments, folderAndFile + [.symbol(outer), .symbol(inner)])
        XCTAssertEqual(model(line: 23).segments, folderAndFile + [.symbol(outer)], "between a field and a method")
    }

    func testTheFirstAndLastLineOfARangeAreInsideIt() {
        XCTAssertEqual(model(line: 5).segments.last, .symbol(save))
        XCTAssertEqual(model(line: 9).segments.last, .symbol(save))
        XCTAssertEqual(model(line: 22).segments.last, .symbol(count))
    }

    func testOutsideEverySymbolTheFileIsLast() {
        XCTAssertEqual(model(line: 43).segments, folderAndFile)
        XCTAssertEqual(model(line: nil).segments, folderAndFile, "no cursor reported for this file yet")
    }

    func testAFileAtTheRootHasOnlyTheWorkbenchFolder() {
        let bar = model(line: 1, symbols: [], file: "README")
        XCTAssertEqual(bar.segments, [.folder(name: "acme", path: ""), .file(path: "README")])
    }

    func testSymbolsWithTheSameRangeAreNotNestedInEachOther() {
        // `var a, b: Int` — two names on one line.
        let a = sym("a", .var, 3, 3)
        let b = sym("b", .var, 3, 3)
        XCTAssertEqual(model(line: 3, symbols: [a, b]).segments.last, .symbol(a))
        XCTAssertEqual(model(line: 3, symbols: [a, b]).segments.count, folderAndFile.count + 1)
    }

    func testOutlineSymbolsAreNotSegmentsInAFileWithCode() {
        let heading = sym("Notes", .module, 1, 60, outline: true)
        XCTAssertEqual(model(line: 7, symbols: [heading] + all).segments.last, .symbol(save))
        XCTAssertEqual(model(line: 43, symbols: [heading] + all).segments, folderAndFile)
    }

    func testAMarkdownFileShowsTheNearestHeadingLast() {
        let file = "docs/guide.md"
        let title = sym("Guide", .module, 1, 30, outline: true, file: file)
        let setup = sym("Setup", .module, 5, 14, container: "Guide", outline: true, file: file)
        let usage = sym("Usage", .module, 15, 30, container: "Guide", outline: true, file: file)
        let bar = model(line: 9, symbols: [title, setup, usage], language: "markdown", file: file)
        XCTAssertEqual(bar.segments, [.folder(name: "acme", path: ""), .folder(name: "docs", path: "docs"),
                                      .file(path: file), .symbol(setup)])
        XCTAssertEqual(model(line: 2, symbols: [title, setup, usage], language: "markdown", file: file).segments.last, .symbol(title))
    }

    // MARK: Status at the end

    func testALanguageTheIndexDoesNotReadSaysTextSearch() {
        let bar = model(line: 3, symbols: [], language: "", file: "notes/todo.txt")
        XCTAssertEqual(bar.status, .textSearch(language: "TXT"))
        XCTAssertEqual(bar.status?.text, "Language TXT: text search")
    }

    func testAFileWithNoExtensionIsNamedByItsName() {
        let bar = model(line: 3, symbols: [], language: "", file: "deploy/Procfile")
        XCTAssertEqual(bar.status?.text, "Language Procfile: text search")
    }

    func testAFileTheReadyIndexHasNotListedSaysTextSearch() {
        XCTAssertEqual(model(line: 1, symbols: [], language: nil, file: "a/new.pl").status, .textSearch(language: "PL"))
    }

    func testAFileNotIndexedYetWhileIndexingSaysIndexing() {
        let bar = model(line: 1, symbols: [], language: nil, state: .indexing(done: 3, total: 10))
        XCTAssertEqual(bar.status, .indexing)
        XCTAssertEqual(bar.status?.text, "Indexing…")
        XCTAssertNil(model(line: 1, language: "swift", state: .indexing(done: 3, total: 10)).status, "an indexed file says nothing")
        XCTAssertNil(model(line: 1, symbols: [], language: nil, state: .idle).status)
    }

    func testAFailedIndexShowsTheFailureInstead() {
        let failure = "code index exited with status 2: unreadable folder"
        let bar = model(line: 7, language: "", state: .failed(failure))
        XCTAssertEqual(bar.status, .indexFailed(failure))
        XCTAssertEqual(bar.status?.text, failure)
        XCTAssertEqual(model(line: 7, state: .failed(failure)).status?.text, failure, "also for an indexed language")
    }

    // MARK: Save state (the old path line's)

    func testTheSaveStateReadsAsThePathLineDid() {
        XCTAssertEqual(JumpBarSaveState(hasError: false, deletedOnDisk: false, isDirty: false).text, "Saved")
        XCTAssertEqual(JumpBarSaveState(hasError: false, deletedOnDisk: false, isDirty: true).text, "Edited")
        XCTAssertEqual(JumpBarSaveState(hasError: false, deletedOnDisk: true, isDirty: false).text, "Deleted")
        XCTAssertEqual(JumpBarSaveState(hasError: true, deletedOnDisk: true, isDirty: true).text, "Not saved", "an error wins")
    }

    // MARK: Menus

    func testTheFolderMenuListsItsSubfoldersAndFiles() {
        let files = ["Sources/App/Store.swift", "Sources/App/Views/List.swift", "Sources/App/Views/Row.swift",
                     "Sources/App/b.swift", "Sources/App/A.swift", "Sources/Other/x.swift", "README.md"]
        let listing = JumpBarFolderListing(folder: "Sources/App", files: files)
        XCTAssertEqual(listing.subfolders, ["Sources/App/Views"])
        XCTAssertEqual(listing.files, ["Sources/App/A.swift", "Sources/App/b.swift", "Sources/App/Store.swift"])
        let root = JumpBarFolderListing(folder: "", files: files)
        XCTAssertEqual(root.subfolders, ["Sources"])
        XCTAssertEqual(root.files, ["README.md"])
    }

    func testTheFolderAndFileSegmentsOpenTheirFolderListing() {
        let bar = model(line: 7)
        let files = ["Sources/App/Store.swift", "Sources/App/Model.swift", "Sources/Main.swift"]
        XCTAssertEqual(bar.menuContent(forSegment: 1, symbols: all, files: files),
                       .folder(JumpBarFolderListing(folder: "Sources", files: files)))
        XCTAssertEqual(bar.menuContent(forSegment: 3, symbols: all, files: files),
                       .folder(JumpBarFolderListing(folder: "Sources/App", files: files)), "the file: its siblings")
    }

    func testATypeSegmentListsTheTypesBesideIt() {
        let bar = model(line: 7)
        XCTAssertEqual(bar.menuContent(forSegment: 4, symbols: all, files: []), .members([outer, other]), "top-level types")
        XCTAssertEqual(bar.menuContent(forSegment: 5, symbols: all, files: []), .members([inner]), "the types in Outer")
    }

    func testAMethodSegmentThatIsNotLastListsTheMembersOfItsType() {
        // A local function inside `save` makes `save` a middle segment.
        let local = sym("step", .function, 6, 7, container: "Inner")
        let symbols = all + [local]
        let bar = model(line: 6, symbols: symbols)
        XCTAssertEqual(bar.segments.last, .symbol(local))
        XCTAssertEqual(bar.menuContent(forSegment: 6, symbols: symbols, files: []), .members([save, load]))
    }

    func testTheLastSegmentListsTheFilesSymbolsIndentedByNesting() {
        let heading = sym("MARK", .module, 44, 44, outline: true)
        let symbols = all + [heading]
        let bar = model(line: 7, symbols: symbols)
        guard case let .fileSymbols(rows) = bar.menuContent(forSegment: bar.segments.count - 1, symbols: symbols, files: []) else {
            return XCTFail("the last segment lists the file's symbols")
        }
        XCTAssertEqual(rows.map(\.symbol.name), ["Outer", "Inner", "save", "load", "count", "flush", "MARK", "helper", "Other"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2, 1, 1, 0, 0, 0])
    }

    func testTheFileAsLastSegmentListsTheSymbolsWhenThereAreSome() {
        let bar = model(line: 43)
        guard case .fileSymbols = bar.menuContent(forSegment: 3, symbols: all, files: []) else {
            return XCTFail("no symbol at the cursor: the file segment is last and lists the symbols")
        }
        let empty = model(line: 1, symbols: [])
        XCTAssertEqual(empty.menuContent(forSegment: 3, symbols: [], files: [path]),
                       .folder(JumpBarFolderListing(folder: "Sources/App", files: [path])), "no symbols: its siblings")
    }

    func testRowsOfNoSymbolsAreEmpty() {
        XCTAssertEqual(JumpBarSymbolRow.rows(for: []), [])
        XCTAssertEqual(JumpBarSymbolRow.rows(for: [helper]).map(\.depth), [0])
    }

    func testTheFilterMatchesTheNameIgnoringCase() {
        let row = JumpBarSymbolRow(symbol: save, depth: 2)
        XCTAssertTrue(row.matches(""))
        XCTAssertTrue(row.matches("SA"))
        XCTAssertTrue(row.matches(" av "), "surrounding spaces ignored")
        XCTAssertFalse(row.matches("load"))
    }
}
