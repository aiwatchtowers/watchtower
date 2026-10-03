import XCTest
@testable import WatchtowerCore

/// The JSON-line streams of `watchtower code index` and `code search`
/// (spec §5, §6.2): framing across reads, a bad line skipped and counted,
/// the done line told apart by `done` (its `symbols` is a count).
final class CodeIndexStreamTests: XCTestCase {
    private static let fileLine = #"{"file":"Sources/a.swift","lang":"swift","symbols":[{"name":"saveNow","kind":"method","#
        + #""path":"Sources/a.swift","line":182,"col":10,"end_line":215,"container":"CodeFileBuffer","#
        + #""signature":"func saveNow() -> Bool","doc":"Writes text.","lang":"swift"}]}"#

    func testFileLineDecodesTheSymbolContract() throws {
        var decoder = CodeJSONLineDecoder<CodeIndexLine>()
        let lines = decoder.feed(Data((Self.fileLine + "\n").utf8))
        guard case let .file(result) = try XCTUnwrap(lines.first) else { return XCTFail("not a file line: \(lines)") }
        XCTAssertEqual(result.file, "Sources/a.swift")
        XCTAssertEqual(result.lang, "swift")
        XCTAssertEqual(result.symbols, [CodeSymbol(
            name: "saveNow", kind: .method, path: "Sources/a.swift", line: 182, col: 10, endLine: 215,
            container: "CodeFileBuffer", signature: "func saveNow() -> Bool", doc: "Writes text.", lang: "swift", outline: false
        )])
    }

    func testAPartialLineWaitsForItsEnd() {
        var decoder = CodeJSONLineDecoder<CodeIndexLine>()
        let bytes = Array((Self.fileLine + "\n" + #"{"done":true,"files":1,"symbols":1,"ms":3}"# + "\n").utf8)
        let cut = 57
        XCTAssertEqual(decoder.feed(Data(bytes[..<cut])), [])
        let lines = decoder.feed(Data(bytes[cut...]))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.last, .done(CodeIndexDone(files: 1, symbols: 1, ms: 3)))
        XCTAssertEqual(decoder.malformedCount, 0)
    }

    func testMalformedLinesAreSkippedAndCounted() {
        var decoder = CodeJSONLineDecoder<CodeIndexLine>()
        let input = "not json\n" + #"{"file":"a.go","lang":"go","symbols":[{"name":"x","kind":"lambda"}]}"# + "\n"
            + #"{"file":"b.go","lang":"","symbols":[]}"# + "\n\n" + "\u{FF}\u{FE}\n"
        let lines = decoder.feed(Data(input.utf8))
        XCTAssertEqual(lines, [.file(CodeIndexFileResult(file: "b.go", lang: "", symbols: []))])
        XCTAssertEqual(decoder.malformedCount, 3, "blank lines are not malformed")
    }

    func testSkippedFlag() {
        var decoder = CodeJSONLineDecoder<CodeIndexLine>()
        let input = #"{"file":"dist/x.js","lang":"","symbols":[],"skipped":true}"# + "\n"
            + #"{"file":"notes.txt","lang":"","symbols":[]}"# + "\n"
        XCTAssertEqual(decoder.feed(Data(input.utf8)), [
            .file(CodeIndexFileResult(file: "dist/x.js", lang: "", symbols: [], skipped: true)),
            .file(CodeIndexFileResult(file: "notes.txt", lang: "", symbols: [], skipped: false))
        ])
    }

    func testDeletedLineAndUnterminatedTail() {
        var decoder = CodeJSONLineDecoder<CodeIndexLine>()
        XCTAssertEqual(decoder.feed(Data(#"{"file":"./gone.go","deleted":true}"#.utf8)), [])
        XCTAssertEqual(decoder.finish(), [.deleted("./gone.go")])
    }

    func testOutlineFlagDefaultsToFalse() throws {
        var decoder = CodeJSONLineDecoder<CodeIndexLine>()
        let line = #"{"file":"README.md","lang":"markdown","symbols":[{"name":"Intro","kind":"module","path":"README.md","#
            + ##""line":1,"col":3,"end_line":4,"container":"","signature":"# Intro","doc":"","lang":"markdown","outline":true}]}"##
        guard case let .file(result) = try XCTUnwrap(decoder.feed(Data((line + "\n").utf8)).first) else { return XCTFail("no file line") }
        XCTAssertEqual(result.symbols.map(\.outline), [true])
        XCTAssertFalse(CodeSymbol(name: "a", kind: .var, path: "a", line: 1, col: 1, endLine: 1).outline)
    }

    func testSearchLines() {
        var decoder = CodeJSONLineDecoder<CodeSearchLine>()
        let input = #"{"path":"a.go","line":3,"col":5,"text":"x := saveNow()","text_col":6,"before":["a"],"after":[]}"# + "\n"
            + #"{"done":true,"files":12,"matches":1,"truncated":false}"# + "\n"
        XCTAssertEqual(decoder.feed(Data(input.utf8)), [
            .match(CodeSearchMatch(path: "a.go", line: 3, col: 5, text: "x := saveNow()", textCol: 6, before: ["a"], after: [])),
            .done(CodeSearchDone(files: 12, matches: 1, truncated: false))
        ])
    }

    func testSearchOptionsArguments() {
        let options = CodeSearchOptions(query: "-x", word: true, caseSensitive: true, regex: false, max: 50, context: 0)
        XCTAssertEqual(
            options.arguments(folder: "/tmp/acme"),
            ["code", "search", "--folder", "/tmp/acme", "--query=-x", "--word", "--case", "--max", "50", "--context", "0", "--json"]
        )
    }
}
