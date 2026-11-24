@testable import WatchtowerChatText
import XCTest

/// Spec 2026-11-24-workchat-polish §2: the pure scanner behind the Workchat's IDE-style colouring of the agent's text.
final class AgentTextHighlightsTests: XCTestCase {
    private struct Found: Equatable {
        let text: String
        let kind: AgentTextHighlights.Kind
    }

    private func found(_ text: String) -> [Found] {
        AgentTextHighlights.spans(inPlain: text).map { span in
            XCTAssertEqual(String(text[span.range]), span.text, "a span's text is the text at its range")
            return Found(text: span.text, kind: span.kind)
        }
    }

    func testPlainTextTable() {
        let cases: [(String, [Found], UInt)] = [
            ("Round 3 of #2188 is ready", [Found(text: "#2188", kind: .ref(2188))], #line),
            ("#2189 is still with the implementer.", [Found(text: "#2189", kind: .ref(2189))], #line),
            ("see https://x.example.com/#123", [], #line),
            ("# 12 heading", [], #line),
            ("issue#12 and #1234567 are not refs", [], #line),
            ("(67a59755a)", [Found(text: "67a59755a", kind: .hash)], #line),
            ("deadbeef", [], #line),
            ("12345678", [], #line),
            (String(repeating: "a1", count: 20) + "b", [], #line),
            ("file CloudKitTransport+LinkDirect.swift is noise",
             [Found(text: "CloudKitTransport+LinkDirect.swift", kind: .path)], #line),
            ("internal/sessionhost/prompt_state.go",
             [Found(text: "internal/sessionhost/prompt_state.go", kind: .path)], #line),
            ("see internal/sessionhost/prompt_state.go.",
             [Found(text: "internal/sessionhost/prompt_state.go", kind: .path)], #line),
            ("e.g.", [], #line),
            ("v0.29.3", [], #line),
            ("https://example.com/a/b.go", [], #line),
            ("Round 3 of #2188 is ready (67a59755a). See docs/a.md",
             [Found(text: "#2188", kind: .ref(2188)), Found(text: "67a59755a", kind: .hash),
              Found(text: "docs/a.md", kind: .path)], #line)
        ]
        for (text, expected, line) in cases {
            XCTAssertEqual(found(text), expected, text, line: line)
        }
    }

    /// A path candidate may not resolve in the app: a ref inside it is listed too, and the app keeps one or the
    /// other (review round 1, `#2201/T2`).
    func testARefInsideAPathCandidateIsListedToo() {
        XCTAssertEqual(found("see #2201/T2 now"),
                       [Found(text: "#2201", kind: .ref(2201)), Found(text: "2201/T2", kind: .path)])
    }

    /// Web-address detection is linear: one pass per stretch, not one per token (review round 1, a long compact JSON
    /// line). Counted in scan steps, never in time.
    func testScanStepsGrowLinearlyOnALongUnspacedLine() {
        func steps(_ copies: Int) -> Int {
            let line = String(repeating: #"{"path":"a/b.go","sha":"67a59755a","n":12},"#, count: copies)
            var steps = 0
            _ = AgentTextHighlights.spans(inPlain: line, steps: &steps)
            XCTAssertLessThanOrEqual(steps, 4 * line.utf16.count, "steps stay linear in the text")
            return steps
        }
        let small = steps(1_200) // ~50 KB
        let large = steps(2_400)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThanOrEqual(Double(large) / Double(small), 2.2)
    }

    func testAHashInsideAPathIsThePathOnly() {
        XCTAssertEqual(found("build/abc1234/out.go"), [Found(text: "build/abc1234/out.go", kind: .path)])
    }

    func testCommandSpanInInlineCode() {
        for code in ["make test-swift", "go test ./internal/db", "swift test", "git log", "gh pr view",
                     "xcodebuild -scheme X", "npm run build", "./scripts/leak-check.sh"] {
            let span = AgentTextHighlights.commandSpan(inCode: code)
            XCTAssertEqual(span?.kind, .command, code)
            XCTAssertEqual(span?.text, code, code)
        }
        XCTAssertNil(AgentTextHighlights.commandSpan(inCode: "foo bar"))
        XCTAssertNil(AgentTextHighlights.commandSpan(inCode: "makefile"))
        XCTAssertNil(AgentTextHighlights.commandSpan(inCode: ""))
    }

    func testCommandSpanTrimsSurroundingSpace() {
        let code = " make lint-all "
        let span = AgentTextHighlights.commandSpan(inCode: code)
        XCTAssertEqual(span?.text, "make lint-all")
        XCTAssertEqual(span.map { String(code[$0.range]) }, "make lint-all")
    }
}
