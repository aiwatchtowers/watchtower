import XCTest
@testable import WatchtowerCore

/// The list's search (spec "The list" → search): the trimmed query against
/// a row's title and preview, case- and diacritic-insensitive; sections
/// left with no rows are dropped.
final class InboxListFilterTests: XCTestCase {
    private static func row(_ id: String, title: String, preview: String = "") -> InboxFolderListRow {
        InboxFolderListRow(id: id, content: InboxRowContent(kind: .threads, title: title, preview: preview))
    }

    func testFilterIgnoresCaseAndDiacritics() {
        let content = InboxRowContent(kind: .threads, title: "Café opening")
        XCTAssertTrue(InboxListFilter.matches(content, query: "cafe"))
        XCTAssertTrue(InboxListFilter.matches(content, query: "  CAFÉ  "))
        XCTAssertFalse(InboxListFilter.matches(content, query: "tea"))
    }

    func testFilterMatchesPreviewToo() {
        let content = InboxRowContent(
            kind: .mailWaiting, title: "Mail waiting", preview: "Colleague A asks about the budget",
            meta: "release notes")
        XCTAssertTrue(InboxListFilter.matches(content, query: "budget"))
        XCTAssertFalse(InboxListFilter.matches(content, query: "release"), "the meta line is not searched")
    }

    func testEmptyQueryKeepsEverything() {
        let sections = [
            InboxListSection(id: "needsYou", title: "Needs you", rows: [Self.row("a", title: "One")]),
            InboxListSection(id: "today", title: "Today", rows: [Self.row("b", title: "Two")], count: 1)
        ]
        XCTAssertEqual(InboxListFilter.apply(sections, query: ""), sections)
        XCTAssertEqual(InboxListFilter.apply(sections, query: "  \n"), sections)
        XCTAssertTrue(InboxListFilter.matches(InboxRowContent(kind: .brief, title: "Morning brief"), query: " "))
    }

    func testEmptySectionsAreDropped() {
        let sections = [
            InboxListSection(id: "needsYou", title: "Needs you", rows: [
                Self.row("a", title: "Waiting for me", preview: "Colleague B: will you approve the budget?"),
                Self.row("b", title: "Mail waiting")
            ]),
            InboxListSection(id: "today", title: "Today", rows: [Self.row("c", title: "Morning brief")]),
            InboxListSection(id: "targets", title: "Targets", rows: [Self.row("d", title: "Budget review")],
                             count: 4)
        ]
        let filtered = InboxListFilter.apply(sections, query: "budget")
        XCTAssertEqual(filtered.map(\.id), ["needsYou", "targets"])
        XCTAssertEqual(filtered.first?.rows.map(\.id), ["a"])
        XCTAssertEqual(filtered.last?.count, 4, "a group keeps its count")
        XCTAssertEqual(InboxListFilter.apply(sections, query: "nothing like it"), [])
    }
}
