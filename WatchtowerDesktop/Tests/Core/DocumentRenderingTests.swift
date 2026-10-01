import XCTest
@testable import WatchtowerCore

final class DocumentRenderingTests: XCTestCase {
    func testHeadingsParagraphsAndSoftBreaksFlattenToPlainText() {
        let doc = DocumentRendering.render("# Title\n\nSome *soft*\nwrapped text.\n\n## Errors\n\nRetry `twice`.")
        XCTAssertEqual(doc.text, "Title\n\nSome soft wrapped text.\n\nErrors\n\nRetry twice.\n\n")
        let errors = (doc.text as NSString).range(of: "Errors").location
        XCTAssertEqual(doc.headings, [
            DocumentHeading(offset: 0, level: 1, title: "Title"),
            DocumentHeading(offset: errors, level: 2, title: "Errors")
        ])
        XCTAssertEqual(doc.headingOffsets.map(\.title), ["Title", "Errors"])
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: 0, length: 5, style: .heading(1))))
        let soft = (doc.text as NSString).range(of: "soft")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: soft.location, length: soft.length, style: .emphasis)))
        let twice = (doc.text as NSString).range(of: "twice")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: twice.location, length: twice.length, style: .code)))
    }

    func testListsGetMarkersAndTaskBoxes() {
        let doc = DocumentRendering.render("- one\n- [x] two\n- [ ] three\n\n1. first\n2. second")
        XCTAssertEqual(doc.text, "• one\n☑ two\n☐ three\n\n1. first\n2. second\n\n")
    }

    func testFencedCodeIsVerbatimAndStyled() {
        let doc = DocumentRendering.render("Intro.\n\n```go\nx := 1\ny := 2\n```")
        XCTAssertEqual(doc.text, "Intro.\n\nx := 1\ny := 2\n\n")
        let code = (doc.text as NSString).range(of: "x := 1\ny := 2")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: code.location, length: code.length, style: .codeBlock)))
    }

    func testLinkRunCarriesItsDestination() {
        let doc = DocumentRendering.render("See [the spec](docs/spec.md).")
        let link = (doc.text as NSString).range(of: "the spec")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: link.location, length: link.length, style: .link("docs/spec.md"))))
    }

    /// The anchors live on this text, so the same markdown must always render
    /// the same text (a re-anchor on an unchanged file finds every quote).
    func testRenderingIsDeterministicAndAnchorsRoundTrip() throws {
        let markdown = "# Plan\n\n## Task 1\n\nWrite the migration.\n\n## Task 2\n\nWrite the migration tests."
        let first = DocumentRendering.render(markdown)
        XCTAssertEqual(first, DocumentRendering.render(markdown))
        let range = try XCTUnwrap(first.text.range(of: "Write the migration."))
        let anchor = CommentAnchor.make(text: first.text, range: range, headings: first.headingOffsets)
        XCTAssertEqual(anchor.heading, "Task 1")
        XCTAssertEqual(anchor.locate(in: DocumentRendering.render(markdown).text), range)
    }

    // MARK: - #181: the comment view renders like the read view

    func testTableCellsAreOneParagraphEachWithoutPipes() {
        let doc = DocumentRendering.render("Before.\n\n| Name | Owner |\n|:--|--:|\n| retry | *ops* |\n| budget |\n\nAfter.")
        XCTAssertFalse(doc.text.contains("|"), "a table never shows its markdown pipes")
        XCTAssertEqual(doc.text, "Before.\n\nName\nOwner\nretry\nops\nbudget\n\n\nAfter.\n\n")
        let cells = doc.runs.compactMap { run -> (String, DocumentTableCell)? in
            guard case let .tableCell(cell) = run.style else { return nil }
            return ((doc.text as NSString).substring(with: NSRange(location: run.location, length: run.length)), cell)
        }
        XCTAssertEqual(cells.map(\.0), ["Name\n", "Owner\n", "retry\n", "ops\n", "budget\n", "\n"],
                       "every cell, a short row's missing one included, is its own paragraph")
        XCTAssertEqual(cells.map { [$0.1.row, $0.1.column] }, [[0, 0], [0, 1], [1, 0], [1, 1], [2, 0], [2, 1]])
        XCTAssertEqual(cells.map(\.1.header), [true, true, false, false, false, false])
        XCTAssertEqual(Set(cells.map(\.1.columns)), [2])
        XCTAssertEqual(Set(cells.map(\.1.table)), [0])
        XCTAssertEqual(cells[1].1.alignment, .trailing)
        let ops = (doc.text as NSString).range(of: "ops")
        XCTAssertTrue(doc.runs.contains(DocumentStyleRun(location: ops.location, length: ops.length, style: .emphasis)))
    }

    func testSeparateTablesGetSeparateIdentities() {
        let doc = DocumentRendering.render("| A |\n|---|\n| 1 |\n\n| B |\n|---|\n| 2 |")
        let tables = Set(doc.runs.compactMap { run -> Int? in
            if case let .tableCell(cell) = run.style { return cell.table }
            return nil
        })
        XCTAssertEqual(tables, [0, 1])
    }

    func testCSVRowsRenderAsATable() {
        let doc = DocumentRendering.renderTable(rows: [["Name", "Owner"], ["retry", "ops"], ["solo"]])
        XCTAssertEqual(doc.text, "Name\nOwner\nretry\nops\nsolo\n\n\n")
        let cells = doc.runs.compactMap { run -> DocumentTableCell? in
            if case let .tableCell(cell) = run.style { return cell }
            return nil
        }
        XCTAssertEqual(cells.map(\.header), [true, true, false, false, false, false])
        XCTAssertEqual(DocumentRendering.renderTable(rows: []).text, "")
    }

    func testListItemsCarryTheirMarkerLengthForAHangingIndent() {
        let doc = DocumentRendering.render("- one\n  - nested\n- [x] two")
        let items = doc.runs.compactMap { run -> (String, Int)? in
            guard case let .listItem(marker) = run.style else { return nil }
            let text = (doc.text as NSString).substring(with: NSRange(location: run.location, length: run.length))
            return (text, marker)
        }
        XCTAssertEqual(items.map(\.1).sorted(), ["• ".utf16.count, "☑ ".utf16.count, "    • ".utf16.count].sorted())
        XCTAssertTrue(items.contains { $0.0.hasPrefix("    • nested") && $0.1 == "    • ".utf16.count })
        XCTAssertTrue(items.contains { $0.0.hasPrefix("• one") }, "the outer item spans its nested list too")
    }

    func testARuleIsALineNotDashes() {
        let doc = DocumentRendering.render("Above.\n\n---\n\nBelow.")
        XCTAssertFalse(doc.text.contains("—"))
        XCTAssertTrue(doc.runs.contains { $0.style == .rule })
    }
}
