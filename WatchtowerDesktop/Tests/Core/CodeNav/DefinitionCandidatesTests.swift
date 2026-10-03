import XCTest
@testable import WatchtowerCore

/// Go to definition's choices (spec §8.2, §6.5): index candidates ordered
/// by nearness to the click then by kind; the text-search heuristic when
/// the index has none; what the click does with them.
final class DefinitionCandidatesTests: XCTestCase {
    private func symbol(
        _ path: String, _ line: Int, kind: CodeSymbolKind = .function, name: String = "save", container: String = ""
    ) -> CodeSymbol {
        CodeSymbol(name: name, kind: kind, path: path, line: line, col: 6, endLine: line + 3, container: container)
    }

    private func match(_ path: String, _ line: Int, col: Int = 1, _ text: String) -> CodeSearchMatch {
        CodeSearchMatch(path: path, line: line, col: col, text: text, textCol: col, before: [], after: [])
    }

    // MARK: Index candidates

    func testOrderIsSameFileThenSameFolderThenSameTopLevelFolderThenTheRest() {
        let symbols = [
            symbol("lib/zeta.go", 1),
            symbol("app/other/deep.go", 2),
            symbol("app/views/list.go", 3),
            symbol("app/views/edit.go", 40),
            symbol("app/views/edit.go", 4),
            symbol("main.go", 5)
        ]
        let ordered = DefinitionCandidates.ordered(symbols, from: "app/views/edit.go")
        XCTAssertEqual(ordered.map { "\($0.path):\($0.line)" }, [
            "app/views/edit.go:4", "app/views/edit.go:40",
            "app/views/list.go:3",
            "app/other/deep.go:2",
            "lib/zeta.go:1", "main.go:5"
        ])
    }

    func testWithinEqualNearnessTypesComeBeforeCallablesBeforeTheRest() {
        let symbols = [
            symbol("x/a.go", 1, kind: .var),
            symbol("x/b.go", 2, kind: .method),
            symbol("x/c.go", 3, kind: .struct),
            symbol("y/d.go", 4, kind: .class)
        ]
        let ordered = DefinitionCandidates.ordered(symbols, from: "x/here.go")
        XCTAssertEqual(ordered.map(\.kind), [.struct, .method, .var, .class],
                       "nearness first: the class in another folder comes last")
    }

    func testTopLevelFilesShareTheRootFolder() {
        let ordered = DefinitionCandidates.ordered(
            [symbol("pkg/a.go", 1), symbol("b.go", 2)], from: "main.go"
        )
        XCTAssertEqual(ordered.map(\.path), ["b.go", "pkg/a.go"])
    }

    func testOneCandidateJumpsAndSeveralAskWithEveryCandidate() {
        let one = symbol("a.go", 3)
        XCTAssertEqual(
            DefinitionCandidates.outcome(for: [one], from: "b.go"),
            .jump(CodeNavLocation(path: "a.go", line: 3, col: 6))
        )
        let many = [symbol("z.go", 1), symbol("b.go", 9)]
        guard case let .choose(choices) = DefinitionCandidates.outcome(for: many, from: "b.go") else {
            return XCTFail("several candidates ask")
        }
        XCTAssertEqual(choices.map(\.target.path), ["b.go", "z.go"])
        XCTAssertEqual(DefinitionCandidates.outcome(for: [], from: "b.go"), .searchText)
    }

    func testAChoiceShowsTypeDotNameAndPathColonLine() {
        let choice = DefinitionChoice(symbol(
            "Sources/Buffer.swift", 182, kind: .method, name: "saveNow", container: "CodeFileBuffer"
        ))
        XCTAssertEqual(choice.title, "CodeFileBuffer.saveNow")
        XCTAssertEqual(choice.location, "Sources/Buffer.swift:182")
        XCTAssertEqual(choice.kind, .method)
        XCTAssertEqual(DefinitionChoice(symbol("a.go", 1)).title, "save", "no container: the name alone")
    }

    func testTheMenuHeaderCountsTheDefinitions() {
        XCTAssertEqual(DefinitionCandidates.menuHeader(word: "save", count: 3, fromTextSearch: false), "save — 3 definitions")
        XCTAssertEqual(DefinitionCandidates.menuHeader(word: "save", count: 4, fromTextSearch: true), "save — 4 text matches")
        XCTAssertEqual(DefinitionCandidates.noDefinitionNotice(word: "save"), "No definition of `save`")
    }

    // MARK: Heuristic (spec §6.5)

    func testDefinitionLooksMatchTheKeywordsBeforeTheName() {
        for line in [
            "func save() {", "  function save(a) {", "def save(self):", "pub fn save() {", "class save:",
            "struct save {", "interface save {", "enum save {", "type save struct {", "proc save {}", "sub save {"
        ] {
            XCTAssertTrue(DefinitionHeuristic.looksLikeDefinition(line, word: "save"), line)
        }
        for line in ["save()", "x = save", "func saveAll() {", "defsave", "// call save later", "funcsave"] {
            XCTAssertFalse(DefinitionHeuristic.looksLikeDefinition(line, word: "save"), line)
        }
    }

    func testAWordWithRegexCharactersIsTakenLiterally() {
        XCTAssertTrue(DefinitionHeuristic.looksLikeDefinition("sub $x.y {", word: "$x.y"))
        XCTAssertFalse(DefinitionHeuristic.looksLikeDefinition("sub $xzy {", word: "$x.y"))
    }

    func testHeuristicPutsDefinitionLooksFirstThenNearnessAndLeavesOutTheClick() {
        let origin = CodeNavLocation(path: "src/run.pl", line: 10, col: 7)
        let matches = [
            match("lib/util.pl", 5, "  save($x);"),
            match("src/run.pl", 10, col: 5, "  save($y);"),
            match("src/run.pl", 30, "  save($z);"),
            match("lib/store.pl", 2, "sub save {"),
            match("src/save.pl", 1, "sub save {")
        ]
        let ranked = DefinitionHeuristic.ranked(matches, word: "save", origin: origin)
        XCTAssertEqual(ranked.map { "\($0.path):\($0.line)" }, [
            "src/save.pl:1", "lib/store.pl:2", "src/run.pl:30", "lib/util.pl:5"
        ])
    }

    /// The page sends the click or cursor column; Monaco finds the word
    /// with the column anywhere from its first character to just after its
    /// last (⌃⌘J with the cursor right after the name).
    func testTheClickedOccurrenceIsLeftOutWhereverInTheWordTheColumnIs() {
        let matches = [match("a.pl", 3, col: 5, "  frob();"), match("b.pl", 9, col: 5, "sub frob {")]
        for col in [5, 7, 9] {
            let origin = CodeNavLocation(path: "a.pl", line: 3, col: col)
            XCTAssertEqual(
                DefinitionHeuristic.ranked(matches, word: "frob", origin: origin).map(\.path), ["b.pl"], "col \(col)"
            )
            XCTAssertEqual(
                DefinitionHeuristic.outcome(for: matches, word: "frob", origin: origin),
                .jump(CodeNavLocation(path: "b.pl", line: 9, col: 5)), "col \(col)"
            )
        }
        for col in [4, 10] {
            let origin = CodeNavLocation(path: "a.pl", line: 3, col: col)
            XCTAssertEqual(DefinitionHeuristic.ranked(matches, word: "frob", origin: origin).count, 2, "col \(col) is outside the word")
        }
    }

    func testHeuristicOutcome() {
        let origin = CodeNavLocation(path: "a.pl", line: 1, col: 1)
        XCTAssertEqual(DefinitionHeuristic.outcome(for: [], word: "w", origin: origin), .notFound)
        XCTAssertEqual(
            DefinitionHeuristic.outcome(for: [match("a.pl", 1, "w")], word: "w", origin: origin), .notFound,
            "only the clicked word itself"
        )
        XCTAssertEqual(
            DefinitionHeuristic.outcome(for: [match("b.pl", 4, col: 5, "sub w {")], word: "w", origin: origin),
            .jump(CodeNavLocation(path: "b.pl", line: 4, col: 5))
        )
        guard case let .choose(choices) = DefinitionHeuristic.outcome(
            for: [match("b.pl", 4, col: 5, "  w();"), match("c.pl", 2, col: 5, "sub w {")], word: "w", origin: origin
        ) else {
            return XCTFail("several matches ask")
        }
        XCTAssertEqual(choices.map(\.location), ["c.pl:2", "b.pl:4"])
        XCTAssertEqual(choices.map(\.title), ["sub w {", "w();"], "the line, trimmed")
        XCTAssertNil(choices[0].kind)
    }

    func testHeuristicChoicesAreCapped() {
        let origin = CodeNavLocation(path: "a.pl", line: 1, col: 1)
        let matches = (1...80).map { match("b.pl", $0, "w") }
        guard case let .choose(choices) = DefinitionHeuristic.outcome(for: matches, word: "w", origin: origin) else {
            return XCTFail("several matches ask")
        }
        XCTAssertEqual(choices.count, DefinitionHeuristic.menuCap)
    }
}
