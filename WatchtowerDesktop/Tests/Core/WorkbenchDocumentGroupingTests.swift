import XCTest
import GRDB
@testable import WatchtowerCore

final class WorkbenchDocumentGroupingTests: XCTestCase {
    private func item(_ id: Int64, _ relPath: String, kind: String, title: String = "", origin: String = "agent")
        -> WorkbenchDocumentListItem {
        let row: Row = ["id": id, "project_id": 1, "rel_path": relPath, "kind": kind, "title": title,
                        "created_at": "", "updated_at": "", "origin": origin]
        return WorkbenchDocumentListItem(document: WorkbenchDocument(row: row), targetTitle: nil, openComments: 0)
    }

    private lazy var items = [
        item(1, "docs/plans/sync-plan.md", kind: "plan", title: "Sync plan"),
        item(2, "docs/specs/sync.md", kind: "spec", title: "Sync spec"),
        item(3, "README.md", kind: "doc", origin: "import"),
        item(4, "docs/specs/old.md", kind: "spec", title: "Old spec", origin: "import"),
        item(5, "notes/idea.md", kind: "doc", title: "Idée", origin: "owner"),
        item(6, "docs/specs/auth.md", kind: "spec", title: "Auth spec")
    ]

    func testGroupsByKindInFixedOrderWithImportsApartAndListOrderKept() {
        let sections = WorkbenchDocumentGrouping.sections(items, query: "")
        XCTAssertEqual(sections.map(\.group), [.specs, .plans, .docs, .imported])
        XCTAssertEqual(sections.map { $0.items.map(\.id) }, [[2, 6], [1], [5], [3, 4]],
                       "an imported spec sits under Imported; order inside a group is the list's")
        XCTAssertEqual(sections.map(\.group.title), ["Specs", "Plans", "Docs", "Imported"])
    }

    func testSearchMatchesTitleOrPathIgnoringCaseAndDiacriticsAndDropsEmptyGroups() {
        XCTAssertEqual(WorkbenchDocumentGrouping.sections(items, query: "SYNC").flatMap { $0.items.map(\.id) }, [2, 1])
        XCTAssertEqual(WorkbenchDocumentGrouping.sections(items, query: "idee").map(\.group), [.docs])
        XCTAssertEqual(WorkbenchDocumentGrouping.sections(items, query: "readme").map(\.group), [.imported],
                       "an untitled document matches by its file name")
        XCTAssertTrue(WorkbenchDocumentGrouping.sections(items, query: "nothing").isEmpty)
        XCTAssertEqual(WorkbenchDocumentGrouping.sections(items, query: "  ").count, 4, "a blank query shows everything")
    }
}
