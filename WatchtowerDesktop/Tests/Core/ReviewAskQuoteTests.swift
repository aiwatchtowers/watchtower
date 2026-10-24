import XCTest
@testable import WatchtowerCore

/// Ask agent's quotes (board #962, spec §4): what lands at the top of the
/// session's Workchat draft.
final class ReviewAskQuoteTests: XCTestCase {
    func testCodeQuoteFormat() {
        let quote = ReviewAskQuote.code(path: "a/b.swift", side: "new", startLine: 31, endLine: 34,
                                        lines: ["let a = 1", "let b = 2", "", "return a + b"])
        XCTAssertEqual(quote, "Re `a/b.swift:31–34`:\n```\nlet a = 1\nlet b = 2\n\nreturn a + b\n```")
        let old = ReviewAskQuote.code(path: "a/b.swift", side: "old", startLine: 31, endLine: 32, lines: ["x", "y"])
        XCTAssertEqual(old, "Re `a/b.swift:31–32` (old side):\n```\nx\ny\n```")
    }

    func testCodeQuoteCapsAt40Lines() {
        let lines = (1...500).map { "line \($0)" }
        let quote = ReviewAskQuote.code(path: "big.go", side: "new", startLine: 1, endLine: 500, lines: lines)
        let body = quote.components(separatedBy: "\n")
        // Header, fence, 40 lines, the cut mark, fence.
        XCTAssertEqual(body.count, 1 + 1 + ReviewAskQuote.maxLines + 1 + 1)
        XCTAssertEqual(ReviewAskQuote.maxLines, 40)
        XCTAssertEqual(body[2], "line 1")
        XCTAssertEqual(body[41], "line 40")
        XCTAssertEqual(body[42], "…")
        XCTAssertEqual(body.last, "```")
        XCTAssertFalse(quote.contains("line 41"))
    }

    /// The preview quotes the current file: no side mark, a selection ending
    /// at column 1 of a later line stops on the line before, and an empty
    /// selection quotes the cursor's line.
    func testCurrentFileQuote() {
        let text = "one\ntwo\nthree\nfour"
        XCTAssertEqual(ReviewAskQuote.current(path: "a.go", text: text, startLine: 2, endLine: 3, endCol: 4),
                       "Re `a.go:2–3`:\n```\ntwo\nthree\n```")
        XCTAssertEqual(ReviewAskQuote.current(path: "a.go", text: text, startLine: 2, endLine: 4, endCol: 1),
                       "Re `a.go:2–3`:\n```\ntwo\nthree\n```")
        XCTAssertEqual(ReviewAskQuote.current(path: "a.go", text: text, startLine: 4, endLine: 4, endCol: 1),
                       "Re `a.go:4`:\n```\nfour\n```")
    }

    func testSingleLineUsesOneNumber() {
        let quote = ReviewAskQuote.code(path: "a/b.swift", side: "new", startLine: 31, endLine: 31, lines: ["x"])
        XCTAssertTrue(quote.hasPrefix("Re `a/b.swift:31`:\n"), quote)
    }

    /// Code holding a fence of its own is wrapped in a longer one.
    func testFenceOutgrowsBackticksInTheCode() {
        let quote = ReviewAskQuote.code(path: "README.md", side: "new", startLine: 1, endLine: 3,
                                        lines: ["```swift", "x", "```"])
        XCTAssertEqual(quote, "Re `README.md:1–3`:\n````\n```swift\nx\n```\n````")
    }

    func testRiskQuote() {
        let quote = ReviewAskQuote.risk(path: "internal/db/x.go", level: "high", why: "The write runs outside the transaction.")
        XCTAssertEqual(quote, "Re `internal/db/x.go` — the AI overview flags a high risk: The write runs outside the transaction.")
    }

    func testLinesOfASelection() {
        let text = "one\ntwo\nthree\nfour"
        XCTAssertEqual(ReviewAskQuote.lines(of: text, startLine: 2, endLine: 3), ["two", "three"])
        // Out of range ends are clamped; an inverted range is empty.
        XCTAssertEqual(ReviewAskQuote.lines(of: text, startLine: 0, endLine: 9), ["one", "two", "three", "four"])
        XCTAssertEqual(ReviewAskQuote.lines(of: text, startLine: 3, endLine: 2), [])
    }

    func testPrependKeepsTheDraftUnderABlankLine() {
        XCTAssertEqual(ReviewAskQuote.prepend("Q", to: ""), "Q\n\n")
        XCTAssertEqual(ReviewAskQuote.prepend("Q", to: "why?"), "Q\n\nwhy?")
    }
}
