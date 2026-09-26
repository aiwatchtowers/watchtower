import XCTest
@testable import WatchtowerCore

final class ExternalConnectionInputTests: XCTestCase {

    // MARK: - CommandArgsTokenizer

    func testTokenizeSplitsOnWhitespace() throws {
        XCTAssertEqual(try CommandArgsTokenizer.tokenize("a b c"), ["a", "b", "c"])
    }

    func testTokenizeKeepsDoubleQuotedPathAsOneArg() throws {
        XCTAssertEqual(
            try CommandArgsTokenizer.tokenize("--path \"/a b/c\" --x"),
            ["--path", "/a b/c", "--x"]
        )
    }

    func testTokenizeHandlesSingleQuotes() throws {
        XCTAssertEqual(try CommandArgsTokenizer.tokenize("'single quoted'"), ["single quoted"])
    }

    func testTokenizeIgnoresExtraWhitespace() throws {
        XCTAssertEqual(try CommandArgsTokenizer.tokenize("  spaced   out  "), ["spaced", "out"])
    }

    func testTokenizeEmptyInputYieldsNoArgs() throws {
        XCTAssertEqual(try CommandArgsTokenizer.tokenize(""), [])
    }

    func testTokenizeExplicitEmptyQuotesYieldOneEmptyArg() throws {
        // Shell semantics: `cmd ""` passes one empty argument on purpose.
        XCTAssertEqual(try CommandArgsTokenizer.tokenize("--flag \"\""), ["--flag", ""])
    }

    func testTokenizeQuoteGluedToWordJoinsIntoOneArg() throws {
        XCTAssertEqual(try CommandArgsTokenizer.tokenize("--flag=\"x y\""), ["--flag=x y"])
    }

    func testTokenizeUnclosedQuoteThrows() {
        XCTAssertThrowsError(try CommandArgsTokenizer.tokenize("--flag \"")) { error in
            XCTAssertEqual(error as? ExternalConnectionInputError, .unclosedQuote)
        }
        XCTAssertThrowsError(try CommandArgsTokenizer.tokenize("'abc"))
    }

    func testTokenizeSplitsOnNonBreakingSpace() throws {
        // Documented deviation from a shell: a pasted NBSP is a separator here.
        XCTAssertEqual(try CommandArgsTokenizer.tokenize("a\u{00A0}b"), ["a", "b"])
    }

    // MARK: - ExternalConnectionSecretBuilder

    private func decode(_ json: String?) throws -> [String: [String: String]] {
        let text = try XCTUnwrap(json)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    func testHTTPKindWrapsPairsUnderHeaders() throws {
        let json = try ExternalConnectionSecretBuilder.json(
            kind: "http",
            pairs: [(key: "Authorization", value: "Bearer x")]
        )
        XCTAssertEqual(try decode(json), ["headers": ["Authorization": "Bearer x"]])
    }

    func testStdioKindWrapsPairsUnderEnv() throws {
        let json = try ExternalConnectionSecretBuilder.json(kind: "stdio", pairs: [(key: "TOKEN", value: "t")])
        XCTAssertEqual(try decode(json), ["env": ["TOKEN": "t"]])
    }

    func testEmptyKeyRowsAreDropped() throws {
        let json = try ExternalConnectionSecretBuilder.json(
            kind: "stdio",
            pairs: [(key: "  ", value: "ignored"), (key: "A", value: "1")]
        )
        XCTAssertEqual(try decode(json), ["env": ["A": "1"]])
    }

    func testDuplicateKeysLastRowWins() throws {
        let json = try ExternalConnectionSecretBuilder.json(
            kind: "stdio",
            pairs: [(key: "A", value: "first"), (key: "A", value: "second")]
        )
        XCTAssertEqual(try decode(json), ["env": ["A": "second"]])
    }

    func testValuesArePassedThroughUntrimmed() throws {
        let json = try ExternalConnectionSecretBuilder.json(kind: "http", pairs: [(key: "X", value: " v ")])
        XCTAssertEqual(try decode(json), ["headers": ["X": " v "]])
    }

    func testAllEmptyRowsYieldNil() throws {
        XCTAssertNil(try ExternalConnectionSecretBuilder.json(
            kind: "http",
            pairs: [(key: "", value: ""), (key: " ", value: "x")]
        ))
        XCTAssertNil(try ExternalConnectionSecretBuilder.json(kind: "http", pairs: []))
    }
}
