import XCTest
@testable import WatchtowerCore

/// The first-turn context of a code question (spec 2026-10-02 §9.1): folder
/// name, path, language, the selection or the cursor line with ±40 lines
/// clipped at the file's edges, and up to 10 index entries for the names it
/// references that the index resolves uniquely.
final class CodeQuestionContextTests: XCTestCase {
    /// "line 1" … "line n", one per line, with a trailing newline.
    private func file(lines count: Int) -> String {
        (1...count).map { "line \($0)" }.joined(separator: "\n") + "\n"
    }

    private func symbol(_ name: String, line: Int = 1) -> CodeSymbol {
        CodeSymbol(name: name, kind: .function, path: "Sources/\(name).swift", line: line, col: 6, endLine: line + 2,
                   signature: "func \(name)()", doc: "Does \(name).", lang: "swift")
    }

    private func build(
        origin: CodeQuestionOrigin, text: String, resolve: (String) -> [CodeSymbol] = { _ in [] }
    ) -> CodeQuestionContext {
        CodeQuestionContext.build(folderName: "acme", origin: origin, language: "swift", fileText: text, resolve: resolve)
    }

    /// A minified 2 MB one-line file: the line is cut at 400 characters and
    /// the block stays within 32 KB.
    func testAOneLineTwoMegabyteFileIsCut() {
        let huge = String(repeating: "x", count: 2 * 1024 * 1024)
        let context = build(origin: CodeQuestionOrigin(path: "dist/app.min.js", line: 1, selection: nil), text: huge)
        XCTAssertEqual(context.focusText.count, CodeQuestionContext.contextLineLimit + 1, "400 characters and …")
        XCTAssertEqual(context.surrounding.map(\.count), [CodeQuestionContext.contextLineLimit + 1])
        XCTAssertTrue(context.focusWasCut)
        XCTAssertLessThanOrEqual(context.promptBlock.utf8.count, CodeQuestionContext.maxPromptBytes)
        XCTAssertFalse(context.promptBlock.contains(String(repeating: "x", count: CodeQuestionContext.contextLineLimit + 1)))

        let selected = build(origin: CodeQuestionOrigin(path: "dist/app.min.js", line: 1, selection: CodeQuestionSelection(
            startLine: 1, endLine: 1, text: huge)), text: huge)
        XCTAssertTrue(selected.focusWasCut)
        XCTAssertTrue(selected.promptBlock.contains("suggest no `wt-edit`"))
        XCTAssertLessThanOrEqual(selected.promptBlock.utf8.count, CodeQuestionContext.maxPromptBytes)
    }

    /// 81 lines of 399 multi-byte characters stay uncut per line but the
    /// whole block is capped, with a note.
    func testTheWholeBlockIsCappedAt32KB() {
        let line = String(repeating: "é", count: 399)
        let text = Array(repeating: line, count: 200).joined(separator: "\n")
        let context = build(origin: CodeQuestionOrigin(path: "a.txt", line: 100, selection: nil), text: text)
        XCTAssertFalse(context.focusWasCut)
        let block = context.promptBlock
        XCTAssertLessThanOrEqual(block.utf8.count, CodeQuestionContext.maxPromptBytes)
        XCTAssertTrue(block.hasSuffix(CodeQuestionContext.cutNote + "\n"))
    }

    /// R56 gap: a multibyte selection whose lines stay under 400 characters
    /// but whose bytes pass 32 KB is cut by the block cap — the model never
    /// sees all of it, so the context reports it and the prompt says so.
    func testAMultibyteSelectionPastTheCapIsReportedCut() {
        for word in ["漢字仮名交じり文", "Привет, мир"] {
            let line = String(repeating: word, count: 300 / word.count)
            let text = Array(repeating: line, count: 80).joined(separator: "\n")
            XCTAssertGreaterThan(text.utf8.count, CodeQuestionContext.maxPromptBytes)
            let context = build(origin: CodeQuestionOrigin(path: "a.txt", line: 1, selection: CodeQuestionSelection(
                startLine: 1, endLine: 80, text: text)), text: text)
            XCTAssertFalse(context.focusLinesWereCut, "no line passes 400 characters")
            XCTAssertTrue(context.focusWasCut, word)
            XCTAssertTrue(context.promptBlock.contains("suggest no `wt-edit`"), word)
            XCTAssertLessThanOrEqual(context.promptBlock.utf8.count, CodeQuestionContext.maxPromptBytes)
        }
        let small = "Привет\nмир"
        let fits = build(origin: CodeQuestionOrigin(path: "a.txt", line: 1, selection: CodeQuestionSelection(
            startLine: 1, endLine: 2, text: small)), text: small)
        XCTAssertFalse(fits.focusWasCut)
    }

    func testShortLinesAreNotCut() {
        let context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 2, selection: nil), text: file(lines: 3))
        XCTAssertFalse(context.focusWasCut)
        XCTAssertFalse(context.promptBlock.contains(CodeQuestionContext.cutNote))
    }

    func testCarriesFolderPathAndLanguage() {
        let context = build(origin: CodeQuestionOrigin(path: "Sources/App.swift", line: 3, selection: nil),
                            text: file(lines: 5))
        XCTAssertEqual(context.folderName, "acme")
        XCTAssertEqual(context.path, "Sources/App.swift")
        XCTAssertEqual(context.language, "swift")
        let block = context.promptBlock
        XCTAssertTrue(block.contains("acme"))
        XCTAssertTrue(block.contains("Sources/App.swift"))
        XCTAssertTrue(block.contains("swift"))
    }

    func testSelectionCarriesFortyLinesEachSide() {
        let selection = CodeQuestionSelection(startLine: 100, endLine: 102, text: "line 100\nline 101\nline 102")
        let context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 101, selection: selection),
                            text: file(lines: 300))
        XCTAssertTrue(context.isSelection)
        XCTAssertEqual(context.focusLines, 100...102)
        XCTAssertEqual(context.focusText, "line 100\nline 101\nline 102")
        XCTAssertEqual(context.surroundingLines, 60...142)
        XCTAssertEqual(context.surrounding.first, "line 60")
        XCTAssertEqual(context.surrounding.last, "line 142")
        XCTAssertFalse(context.promptBlock.contains("line 59\n"))
        XCTAssertFalse(context.promptBlock.contains("line 143"))
    }

    func testSurroundingIsClippedAtTheFileEdges() {
        let top = build(origin: CodeQuestionOrigin(path: "a.swift", line: 3, selection: nil), text: file(lines: 300))
        XCTAssertEqual(top.surroundingLines, 1...43)
        let bottom = build(origin: CodeQuestionOrigin(path: "a.swift", line: 290, selection: nil), text: file(lines: 300))
        // The trailing newline ends line 300; it starts no line 301.
        XCTAssertEqual(bottom.surroundingLines, 250...300)
        let small = build(origin: CodeQuestionOrigin(path: "a.swift", line: 2, selection: nil), text: "a\nb\nc")
        XCTAssertEqual(small.surroundingLines, 1...3)
        XCTAssertEqual(small.surrounding, ["a", "b", "c"])
    }

    func testEmptySelectionUsesTheCursorLine() {
        let empty = CodeQuestionSelection(startLine: 7, endLine: 7, text: "")
        for origin in [CodeQuestionOrigin(path: "a.swift", line: 7, selection: empty),
                       CodeQuestionOrigin(path: "a.swift", line: 7, selection: nil)] {
            let context = build(origin: origin, text: file(lines: 20))
            XCTAssertFalse(context.isSelection)
            XCTAssertEqual(context.focusLines, 7...7)
            XCTAssertEqual(context.focusText, "line 7")
            XCTAssertTrue(context.promptBlock.contains("Cursor line: 7"))
        }
    }

    /// A cursor past the end (the buffer shrank) lands on the last line.
    func testCursorBeyondTheFileIsClamped() {
        let context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 99, selection: nil), text: "a\nb")
        XCTAssertEqual(context.focusLines, 2...2)
        XCTAssertEqual(context.focusText, "b")
    }

    func testIndexEntriesAreUniqueResolutionsCappedAtTen() {
        let names = (1...12).map { "name\($0)" }
        let text = (names + ["twice", "nothing", "name1"]).joined(separator: "(); ")
        let selection = CodeQuestionSelection(startLine: 1, endLine: 1, text: text)
        var asked: [String] = []
        let context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 1, selection: selection), text: text) { name in
            asked.append(name)
            switch name {
            case "twice": return [self.symbol("twice", line: 1), self.symbol("twice", line: 9)]
            case "nothing": return []
            default: return [self.symbol(name)]
            }
        }
        XCTAssertEqual(context.entries.map(\.name), Array(names.prefix(10)))
        XCTAssertEqual(asked.filter { $0 == "name1" }.count, 1, "each name is looked up once")
        let block = context.promptBlock
        XCTAssertTrue(block.contains("func name1()"))
        XCTAssertTrue(block.contains("Does name1."))
        XCTAssertTrue(block.contains("Sources/name1.swift:1"))
        XCTAssertFalse(block.contains("Sources/name11.swift"), "the eleventh resolved name is left out")
    }

    func testAmbiguousAndUnknownNamesAreLeftOut() {
        let selection = CodeQuestionSelection(startLine: 1, endLine: 1, text: "twice(nothing)")
        let context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 1, selection: selection),
                            text: "twice(nothing)") { name in
            name == "twice" ? [self.symbol("twice"), self.symbol("twice", line: 5)] : []
        }
        XCTAssertTrue(context.entries.isEmpty)
    }

    /// Code holding a fence never closes the block early.
    func testFenceOutrunsBackticksInTheCode() {
        let text = "let s = \"```\"\n"
        let context = build(origin: CodeQuestionOrigin(path: "a.md", line: 1, selection: nil), text: text)
        XCTAssertTrue(context.promptBlock.contains("````"))
    }

    func testContextIDIsWorkbenchPathLine() {
        let origin = CodeQuestionOrigin(path: "Sources/App.swift", line: 12, selection: nil)
        XCTAssertEqual(origin.contextID(workbenchID: 4), "4:Sources/App.swift:12")
    }

    /// Swift reads "\r\n" as one character: a CRLF file must still split
    /// into its lines (the cursor line of a Windows-style file).
    func testCRLFFileSplitsIntoLines() {
        let context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 2, selection: nil), text: "one\r\ntwo\r\nthree\r\n")
        XCTAssertEqual(context.focusText, "two")
        XCTAssertEqual(context.surrounding, ["one", "two", "three"])
    }

    /// Ruling R45: the usage search's locations ride with the context.
    func testUsagesAreListedInThePrompt() {
        var context = build(origin: CodeQuestionOrigin(path: "a.swift", line: 1, selection: nil), text: "load()\n")
        XCTAssertNil(context.usagesBlock)
        context.usages = CodeQuestionUsages(name: "load", locations: [
            CodeQuestionUsages.Location(path: "Sources/App.swift", line: 12, text: "    load()"),
            CodeQuestionUsages.Location(path: "b.swift", line: 3, text: "x = load()")
        ], truncated: true)
        let block = try? XCTUnwrap(context.usagesBlock)
        XCTAssertTrue(block?.contains("Usages of `load`") == true)
        XCTAssertTrue(block?.contains("- Sources/App.swift:12: load()") == true)
        XCTAssertTrue(block?.contains("- b.swift:3: x = load()") == true)
        XCTAssertTrue(block?.contains("more not shown") == true)
        XCTAssertTrue(context.promptBlock.contains("- b.swift:3: x = load()"), "part of the first-turn context")
        context.usages = CodeQuestionUsages(name: "zzz", locations: [], truncated: false)
        XCTAssertTrue(context.usagesBlock?.contains("No usages") == true)
    }
}
