import XCTest
@testable import WatchtowerCore

/// A finished answer's prose as native text runs (spec 2026-10-24 §5b): the
/// segmenting, the paragraph model the app styles, and the memo.
final class MarkdownRunBuilderTests: XCTestCase {
    private func runs(_ segments: [MarkdownSegment]) -> [MarkdownRun] {
        segments.compactMap { if case let .textRun(run, _) = $0 { run } else { nil } }
    }

    func testProseBetweenCodeBlocksIsOneRun() {
        let blocks = MarkdownDocument.parse("""
            Intro **text**.

            # Heading

            - one
            - two

            > quoted

            ```
            code
            ```

            After the code.

            | a | b |
            |---|---|
            | 1 | 2 |

            ---

            Last.
            """)
        let segments = MarkdownRunBuilder.segments(blocks)
        XCTAssertEqual(segments.count, 6)
        guard case let .textRun(first, firstID) = segments[0] else { return XCTFail("the prose is one run") }
        XCTAssertEqual(first.paragraphs.map(\.kind), [.body, .heading(level: 1), .body, .body, .body])
        guard case .block(.code) = segments[1] else { return XCTFail("a code block keeps its own view") }
        guard case let .textRun(second, secondID) = segments[2] else { return XCTFail("prose after the code") }
        XCTAssertEqual(second.paragraphs.map(\.inlines), [[.text("After the code.")]])
        guard case .block(.table) = segments[3], case .block(.rule) = segments[4] else {
            return XCTFail("tables and rules keep their own views")
        }
        guard case .textRun(_, let lastID) = segments[5] else { return XCTFail("the last paragraph") }
        XCTAssertEqual(Set([firstID, secondID, lastID]).count, 3, "every run has its own id")
    }

    /// Spacing between blocks (8) and list items (4), as `MarkdownBlocksView`
    /// and `MarkdownListView` lay them out; the first paragraph of a run has
    /// none (the segments' own stack spaces them).
    func testSpacingFollowsTheBlockAndItemStacks() throws {
        let run = try XCTUnwrap(runs(MarkdownRunBuilder.segments(MarkdownDocument.parse("""
            Para.

            - a
            - b

              b2
            - c
            """))).first)
        let block = MarkdownRunBuilder.blockSpacing, item = MarkdownRunBuilder.itemSpacing
        XCTAssertEqual(run.paragraphs.map(\.spacingBefore), [0, block, item, block, item])
    }

    func testListLevelsAndMarkers() throws {
        let run = try XCTUnwrap(runs(MarkdownRunBuilder.segments(MarkdownDocument.parse("""
            3. three
               - nested
            4. four
            - [x] done
            - [ ] todo
            """))).first)
        let paragraphs = run.paragraphs
        XCTAssertEqual(paragraphs.count, 5)
        XCTAssertEqual(paragraphs[0].levels, [.listItem(.number(3))])
        XCTAssertEqual(paragraphs[0].startsAt, 0, "the item's marker is drawn on its first paragraph")
        XCTAssertEqual(paragraphs[1].levels, [.listItem(.number(3)), .listItem(.bullet)])
        XCTAssertEqual(paragraphs[1].startsAt, 1, "only the nested marker starts here")
        XCTAssertEqual(paragraphs[2].levels, [.listItem(.number(4))])
        XCTAssertEqual(paragraphs[3].levels, [.listItem(.checked)])
        XCTAssertEqual(paragraphs[4].levels, [.listItem(.unchecked)])
    }

    /// An item whose first block is a list draws both markers on one line,
    /// as the SwiftUI marker beside a nested stack does.
    func testAnItemOpeningWithAListStartsBothLevels() throws {
        let run = try XCTUnwrap(runs(MarkdownRunBuilder.segments(MarkdownDocument.parse("- - inner"))).first)
        XCTAssertEqual(run.paragraphs.first?.levels, [.listItem(.bullet), .listItem(.bullet)])
        XCTAssertEqual(run.paragraphs.first?.startsAt, 0)
    }

    func testQuoteLevelsCarryTheirOwnBar() throws {
        let run = try XCTUnwrap(runs(MarkdownRunBuilder.segments(MarkdownDocument.parse("""
            > one
            >
            > two

            > other
            """))).first)
        let quoteIDs = run.paragraphs.map { paragraph -> Int? in
            guard case let .quote(id) = paragraph.levels.first else { return nil }
            return id
        }
        XCTAssertEqual(quoteIDs.count, 3)
        XCTAssertEqual(quoteIDs[0], quoteIDs[1], "one quote, one bar")
        XCTAssertNotEqual(quoteIDs[1], quoteIDs[2], "a second quote draws its own bar")
    }

    /// A list or quote holding a code block, table or rule is rendered by
    /// the SwiftUI path whole: a run never holds a view.
    func testAContainerWithABlockViewStaysABlock() {
        let blocks = MarkdownDocument.parse("- item\n\n  ```\n  code\n  ```\n\n> quote\n>\n> ---\n")
        let segments = MarkdownRunBuilder.segments(blocks)
        XCTAssertEqual(segments.count, 2)
        for segment in segments {
            guard case .block = segment else { return XCTFail("\(segment) should stay a block") }
        }
    }

    func testSegmentsAreMemoised() {
        let blocks = MarkdownDocument.parse("memo \(UUID().uuidString)\n\n- a\n- b")
        XCTAssertEqual(MarkdownRunBuilder.segments(blocks), MarkdownRunBuilder.build(blocks))

        let memo = MarkdownMemo<String, Int>(totalCostLimit: 1 << 10)
        var builds = 0
        let build = { () -> Int in builds += 1; return 42 }
        XCTAssertEqual(memo.value(for: "k", build: build), 42)
        XCTAssertEqual(memo.value(for: "k", build: build), 42)
        XCTAssertEqual(builds, 1, "the repeat is a memo hit")
        _ = memo.value(for: "other", build: build)
        XCTAssertEqual(builds, 2, "the key decides")
    }
}
