import XCTest
@testable import WatchtowerCore

final class CodeHighlighterTests: XCTestCase {
    private func kinds(_ code: String, _ lang: String?) -> [(CodeToken.Kind, String)] {
        CodeHighlighter.tokens(code, language: lang).map { ($0.kind, $0.text) }
    }

    func testSwiftLine() {
        let tokens = CodeHighlighter.tokens(#"let x = "a" // c"#, language: "swift")
        XCTAssertEqual(tokens.first, CodeToken(kind: .keyword, text: "let"))
        XCTAssertTrue(tokens.contains(CodeToken(kind: .string, text: #""a""#)))
        XCTAssertEqual(tokens.last, CodeToken(kind: .comment, text: "// c"))
    }

    func testPythonHashCommentAndNumber() {
        let tokens = CodeHighlighter.tokens("def f(): return 42 # done", language: "py")
        XCTAssertEqual(tokens.first, CodeToken(kind: .keyword, text: "def"))
        XCTAssertTrue(tokens.contains(CodeToken(kind: .number, text: "42")))
        XCTAssertEqual(tokens.last, CodeToken(kind: .comment, text: "# done"))
    }

    func testBlockCommentAndSQLKeywordsAreCaseInsensitive() {
        XCTAssertTrue(CodeHighlighter.tokens("/* a\nb */ x", language: "go").contains(CodeToken(kind: .comment, text: "/* a\nb */")))
        XCTAssertEqual(CodeHighlighter.tokens("select 1", language: "sql").first, CodeToken(kind: .keyword, text: "select"))
    }

    /// Lossless for every language and for unknown ones; never crashes on an
    /// unterminated string or comment.
    func testTokensConcatenateBackToTheInput() {
        let samples = [#"let s = "unterminated"#, "/* open", "x = 'y' + `z` 0x1F", "Привет мир 3.14"]
        for lang in ["swift", "go", "python", "js", "json", "sql", "bash", "yaml", "rust", "unknown-lang", nil] {
            for sample in samples {
                XCTAssertEqual(CodeHighlighter.tokens(sample, language: lang).map(\.text).joined(), sample)
            }
        }
    }

    func testUnknownLanguageIsOnePlainToken() {
        XCTAssertEqual(CodeHighlighter.tokens("let x = 1", language: "brainfuck"), [CodeToken(kind: .plain, text: "let x = 1")])
        XCTAssertEqual(CodeHighlighter.tokens("", language: "swift"), [])
    }

    func testIdentifierContainingDigitsIsNotANumber() {
        XCTAssertFalse(kinds("v2 = 1", "go").contains { $0.0 == .number && $0.1 == "2" })
    }

    /// A streamed, growing code fence must not be fully re-scanned on every
    /// re-render — same memoization contract as `MarkdownDocument.parse`.
    func testTokensAreCachedByCodeAndLanguage() {
        let code = "let cachedHighlighterProbe123 = 1 // unique to this test"
        XCTAssertFalse(CodeHighlighter.isCached(code, language: "swift"))
        let first = CodeHighlighter.tokens(code, language: "swift")
        XCTAssertTrue(CodeHighlighter.isCached(code, language: "swift"))
        XCTAssertEqual(CodeHighlighter.tokens(code, language: "swift"), first)
        // A different language is a different cache entry, not a stale hit.
        XCTAssertFalse(CodeHighlighter.isCached(code, language: "go"))
    }
}
