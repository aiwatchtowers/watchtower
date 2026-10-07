import XCTest
@testable import WatchtowerCore

final class MarkdownDocumentTests: XCTestCase {
    func testHeadingParagraphAndInlines() {
        XCTAssertEqual(MarkdownDocument.parse("# T **b**\n\nx *i* `c` ~~s~~ [l](https://a.b)"), [
            .heading(level: 1, inlines: [.text("T "), .strong([.text("b")])]),
            .paragraph([.text("x "), .emphasis([.text("i")]), .text(" "), .code("c"), .text(" "),
                        .strikethrough([.text("s")]), .text(" "), .link(destination: "https://a.b", children: [.text("l")])])
        ])
    }

    func testNestedListsAndTasks() {
        let blocks = MarkdownDocument.parse("- a\n  - b\n- [x] done\n- [ ] todo")
        XCTAssertEqual(blocks, [.list(MarkdownList(ordered: false, start: 1, items: [
            MarkdownListItem(task: .none, blocks: [
                .paragraph([.text("a")]),
                .list(MarkdownList(ordered: false, start: 1, items: [MarkdownListItem(task: .none, blocks: [.paragraph([.text("b")])])]))
            ]),
            MarkdownListItem(task: .checked, blocks: [.paragraph([.text("done")])]),
            MarkdownListItem(task: .unchecked, blocks: [.paragraph([.text("todo")])])
        ]))])
    }

    func testOrderedListKeepsItsStart() {
        guard case let .list(list) = MarkdownDocument.parse("3. c\n4. d").first else { return XCTFail("no list") }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.start, 3)
    }

    func testTable() {
        XCTAssertEqual(MarkdownDocument.parse("| A | B |\n|:--|--:|\n| 1 | 2 |"), [.table(MarkdownTable(
            header: [[.text("A")], [.text("B")]],
            rows: [[[.text("1")], [.text("2")]]],
            alignments: [.leading, .trailing]))])
    }

    func testFencedCodeQuoteAndRule() {
        XCTAssertEqual(MarkdownDocument.parse("```go\nx := 1\n```\n\n> q\n\n---"), [
            .code(language: "go", code: "x := 1"),
            .quote([.paragraph([.text("q")])]),
            .rule
        ])
    }

    /// Streaming: a fence not yet closed renders as code, not as prose that
    /// jumps into a code block when the closing fence arrives.
    func testUnterminatedFenceIsCode() {
        XCTAssertEqual(MarkdownDocument.parse("Here:\n```swift\nlet x = 1"), [
            .paragraph([.text("Here:")]),
            .code(language: "swift", code: "let x = 1")
        ])
    }

    func testEmptyAndSoftBreaks() {
        XCTAssertEqual(MarkdownDocument.parse(""), [])
        XCTAssertEqual(MarkdownDocument.parse("a\nb"), [.paragraph([.text("a"), .softBreak, .text("b")])])
    }

    func testAttributedInlinesKeepIntentsAndLinks() {
        let attr = MarkdownInlineRenderer.attributed([.strong([.text("b")]), .link(destination: "https://x.y", children: [.text("l")])])
        XCTAssertEqual(String(attr.characters), "bl")
        XCTAssertTrue(attr.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(attr.runs.contains { $0.link?.absoluteString == "https://x.y" })
    }

    func testParseIsMemoizedAndPure() {
        let text = "## H\n\n- one\n- two"
        XCTAssertEqual(MarkdownDocument.parse(text), MarkdownDocument.parse(text))
    }

    // MARK: - Truncated input (streaming: a table or list can arrive mid-row)

    /// No separator row: GFM requires one to recognize a table, so a
    /// streamed header-only line renders as plain text, not a malformed table.
    func testTruncatedTableHeaderOnlyIsNotATable() {
        XCTAssertEqual(MarkdownDocument.parse("| A | B |"), [.paragraph([.text("| A | B |")])])
    }

    func testTruncatedTableHeaderPlusPartialSeparatorDoesNotCrash() {
        let blocks = MarkdownDocument.parse("| A | B |\n|--")
        XCTAssertFalse(blocks.contains { if case .table = $0 { return true }; return false })
    }

    /// A row shorter than the header pads its missing cells rather than
    /// crashing on an out-of-bounds column.
    func testTruncatedTableRaggedRowPadsMissingCells() {
        XCTAssertEqual(MarkdownDocument.parse("| A | B |\n|---|---|\n| 1 |"), [.table(MarkdownTable(
            header: [[.text("A")], [.text("B")]],
            rows: [[[.text("1")], []]],
            alignments: [.leading, .leading]))])
    }

    /// A nested task list truncated at every prefix length never crashes and
    /// always renders as a single list block once non-empty — the streaming
    /// case where the composer keeps typing mid-item/mid-nesting.
    func testTruncatedNestedListNeverCrashesAtAnyPrefixLength() {
        let sample = "- a\n  - b\n- [x] done\n- [ ] todo"
        for length in 0...sample.count {
            let prefix = String(sample.prefix(length))
            let blocks = MarkdownDocument.parse(prefix)
            guard !prefix.isEmpty else {
                XCTAssertEqual(blocks, [], "empty prefix")
                continue
            }
            XCTAssertEqual(blocks.count, 1, "prefix length \(length) (\(prefix.debugDescription)) produced \(blocks.count) top-level blocks")
            guard case .list = blocks.first else {
                return XCTFail("prefix length \(length) (\(prefix.debugDescription)) did not render as a list: \(blocks)")
            }
        }
    }

    /// Owner-written text: one newline is a new line, at any depth; a
    /// fenced block keeps its own text.
    func testWithLineBreaksTurnsSoftBreaksIntoLineBreaks() {
        XCTAssertEqual(MarkdownDocument.withLineBreaks(MarkdownDocument.parse("a\n**b\nc**\n> d\n> e\n\n- f\n  g\n\n```\nh\ni\n```")), [
            .paragraph([.text("a"), .lineBreak, .strong([.text("b"), .lineBreak, .text("c")])]),
            .quote([.paragraph([.text("d"), .lineBreak, .text("e")])]),
            .list(MarkdownList(ordered: false, start: 1, items: [
                MarkdownListItem(task: .none, blocks: [.paragraph([.text("f"), .lineBreak, .text("g")])])
            ])),
            .code(language: nil, code: "h\ni")
        ])
        XCTAssertEqual(MarkdownDocument.parse("a\nb"), [.paragraph([.text("a"), .softBreak, .text("b")])],
                       "the agent's text keeps markdown's soft break")
    }
}
