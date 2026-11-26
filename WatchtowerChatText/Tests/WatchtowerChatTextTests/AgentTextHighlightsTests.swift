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

    func testCodeSpanReadsACommandInInlineCode() {
        for code in ["make test-swift", "go test ./internal/db", "swift test", "git log", "gh pr view",
                     "xcodebuild -scheme X", "npm run build", "./scripts/leak-check.sh"] {
            let span = AgentTextHighlights.codeSpan(inCode: code)
            XCTAssertEqual(span?.kind, .command, code)
            XCTAssertEqual(span?.text, code, code)
        }
        XCTAssertNil(AgentTextHighlights.codeSpan(inCode: "foo bar"))
        XCTAssertNil(AgentTextHighlights.codeSpan(inCode: "makefile"))
        XCTAssertNil(AgentTextHighlights.codeSpan(inCode: ""))
    }

    func testCodeSpanTrimsSurroundingSpace() {
        let code = " make lint-all "
        let span = AgentTextHighlights.codeSpan(inCode: code)
        XCTAssertEqual(span?.text, "make lint-all")
        XCTAssertEqual(span.map { String(code[$0.range]) }, "make lint-all")
    }

    private func kinds(_ text: String) -> [AgentTextHighlights.Kind] {
        found(text).map(\.kind)
    }

    private func texts(_ text: String) -> [String] {
        found(text).map(\.text)
    }

    /// Spec 2026-11-26 §1: `PR #N` and `ask #N` are their own kinds, the whole phrase one span.
    func testPrefixedRefsAreTheirOwnKinds() {
        XCTAssertEqual(kinds("answered in ask #990"), [.ask(990)])
        XCTAssertEqual(kinds("see PR #1124 and pr #7"), [.pullRequest(1124), .pullRequest(7)])
        XCTAssertEqual(texts("ask #990"), ["ask #990"])
        XCTAssertEqual(kinds("target #12"), [.ref(12)])
        XCTAssertEqual(kinds("PR#12"), []) // glued: not the phrase, and the ref rule refuses `#` after a word char
    }

    func testDatesAndTimes() {
        XCTAssertEqual(kinds("since 2026-11-16 at 10:05"), [.time, .time])
        XCTAssertEqual(kinds("ratio 3:2, 24:00, 12:345, 10:05:33, 2026-13-01, v1.2"), [])
    }

    func testCodeSpanTakesTheWholeTokensKind() {
        XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "4d434597")?.kind, .hash)
        XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: " #1169 ")?.text, "#1169")
        XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "\"2026-11-16\"")?.text, "2026-11-16")
        XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "ask #990")?.kind, .ask(990))
        XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "team_kpi.json")?.kind, .path)
        XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "make test")?.kind, .command)
        XCTAssertNil(AgentTextHighlights.codeSpan(inCode: "marking_started: \"2026-11-16\""))
        XCTAssertNil(AgentTextHighlights.codeSpan(inCode: "domain-kpi-v2"))
    }

    func testOnlyTheOldKindsOpen() {
        XCTAssertTrue([.ref(1), .hash, .path, .command].allSatisfy { (kind: AgentTextHighlights.Kind) in kind.opens })
        XCTAssertFalse([.time, .pullRequest(1), .ask(1)].contains { (kind: AgentTextHighlights.Kind) in kind.opens })
    }

    func testADateInsideAPathIsListedInsideTheCandidate() {
        let spans = AgentTextHighlights.spans(inPlain: "logs/2026-11-16.txt")
        XCTAssertEqual(spans.map(\.kind), [.path, .time])
    }

    func testADateGluedToAWordIsNotADate() {
        XCTAssertEqual(kinds("tag v2026-11-16 shipped"), [])
    }

    /// A `#` before a time or a date leaves only the ref: the spans other than paths never overlap.
    func testARefBeforeAColonOrADashIsTheRefOnly() {
        XCTAssertEqual(kinds("#12:30"), [.ref(12)])
        XCTAssertEqual(kinds("#2026-11-16"), [.ref(2026)])
    }

    /// A time ends a sentence as a date does; seconds and dotted numbers stay refused.
    func testATimeMayEndASentence() {
        XCTAssertEqual(kinds("at 10:05."), [.time])
        XCTAssertEqual(kinds("10:05:33"), [])
        XCTAssertEqual(kinds("10:05.1"), [])
    }

    /// `PR #N` / `ask #N` hold on one line: a line break between the word and the ref leaves the ref alone.
    func testAPhraseDoesNotSpanALineBreak() {
        XCTAssertEqual(kinds("ask\n#990"), [.ref(990)])
        XCTAssertEqual(kinds("ask\t#990"), [.ask(990)])
    }
}
