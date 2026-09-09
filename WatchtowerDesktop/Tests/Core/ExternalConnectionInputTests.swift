import XCTest
@testable import WatchtowerCore

final class ExternalConnectionInputTests: XCTestCase {

    // MARK: - CommandArgsTokenizer

    func testTokenizeSplitsOnWhitespace() {
        XCTAssertEqual(CommandArgsTokenizer.tokenize("a b c"), ["a", "b", "c"])
    }

    func testTokenizeKeepsDoubleQuotedPathAsOneArg() {
        XCTAssertEqual(
            CommandArgsTokenizer.tokenize("--path \"/a b/c\" --x"),
            ["--path", "/a b/c", "--x"]
        )
    }

    func testTokenizeHandlesSingleQuotes() {
        XCTAssertEqual(CommandArgsTokenizer.tokenize("'single quoted'"), ["single quoted"])
    }

    func testTokenizeIgnoresExtraWhitespace() {
        XCTAssertEqual(CommandArgsTokenizer.tokenize("  spaced   out  "), ["spaced", "out"])
    }

    func testTokenizeEmptyInputYieldsNoArgs() {
        XCTAssertEqual(CommandArgsTokenizer.tokenize(""), [])
    }

    // MARK: - ExternalConnectionSecretBuilder

    private func decode(_ json: String?) throws -> [String: [String: String]] {
        let text = try XCTUnwrap(json)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    func testHTTPKindWrapsPairsUnderHeaders() throws {
        let json = ExternalConnectionSecretBuilder.json(
            kind: "http",
            pairs: [(key: "Authorization", value: "Bearer x")]
        )
        XCTAssertEqual(try decode(json), ["headers": ["Authorization": "Bearer x"]])
    }

    func testStdioKindWrapsPairsUnderEnv() throws {
        let json = ExternalConnectionSecretBuilder.json(kind: "stdio", pairs: [(key: "TOKEN", value: "t")])
        XCTAssertEqual(try decode(json), ["env": ["TOKEN": "t"]])
    }

    func testEmptyKeyRowsAreDropped() throws {
        let json = ExternalConnectionSecretBuilder.json(
            kind: "stdio",
            pairs: [(key: "  ", value: "ignored"), (key: "A", value: "1")]
        )
        XCTAssertEqual(try decode(json), ["env": ["A": "1"]])
    }

    func testAllEmptyRowsYieldNil() {
        XCTAssertNil(ExternalConnectionSecretBuilder.json(
            kind: "http",
            pairs: [(key: "", value: ""), (key: " ", value: "x")]
        ))
        XCTAssertNil(ExternalConnectionSecretBuilder.json(kind: "http", pairs: []))
    }
}
