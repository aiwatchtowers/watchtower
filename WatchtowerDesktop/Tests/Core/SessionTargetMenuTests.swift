import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class SessionTargetMenuTests: XCTestCase {
    private func target(_ id: Int, _ text: String, status: String = "todo", parent: Int? = nil) throws -> Target {
        let queue = try TestDatabase.create()
        return try queue.write { db in
            if let parent {
                try db.execute(
                    sql: """
                        INSERT INTO targets (id, text, level, period_start, period_end, source_type)
                        VALUES (?, 'parent', 'custom', '2026-09-29', '2026-09-29', 'chat')
                        """,
                    arguments: [parent]
                )
            }
            try db.execute(
                sql: """
                    INSERT INTO targets (id, text, intent, level, custom_label, period_start, period_end,
                        status, source_type, ownership, parent_id)
                    VALUES (?, ?, '', 'custom', 'project', '2026-09-29', '2026-09-29', ?, 'chat', 'mine', ?)
                    """,
                arguments: [id, text, status, parent]
            )
            return try XCTUnwrap(TargetQueries.fetchByID(db, id: id))
        }
    }

    private func node(_ t: Target, _ children: [WorkbenchBoardNode] = [], archived: Bool = false) -> WorkbenchBoardNode {
        WorkbenchBoardNode(target: t, children: children, openComments: 0, unreadForOwner: 0, archived: archived)
    }

    func testStringsAreExact() {
        XCTAssertEqual(SessionTargetMenu.title, "Session Target")
        XCTAssertEqual(SessionTargetMenu.noneTitle, "None — Count What It Touched")
        XCTAssertEqual(
            SessionTargetMenu.failureLine("target 7 is not on this board"),
            "Couldn't change the session target: target 7 is not on this board"
        )
    }

    func testNoneIsCheckedWhenNoTargetIsBound() throws {
        let roots = [node(try target(1, "A"))]
        let items = SessionTargetMenu.items(roots: roots, current: nil)
        XCTAssertEqual(items, [.none(checked: true), .target(id: 1, title: "A", checked: false, children: [])])
    }

    func testTheCurrentTargetIsChecked() throws {
        let roots = [node(try target(1, "A")), node(try target(2, "B"))]
        let items = SessionTargetMenu.items(roots: roots, current: 2)
        XCTAssertEqual(items, [
            .none(checked: false),
            .target(id: 1, title: "A", checked: false, children: []),
            .target(id: 2, title: "B", checked: true, children: [])
        ])
    }

    func testDismissedAndArchivedTargetsAreLeftOut() throws {
        let roots = [
            node(try target(1, "Kept")),
            node(try target(2, "Gone", status: "dismissed")),
            node(try target(3, "Old"), archived: true)
        ]
        let items = SessionTargetMenu.items(roots: roots, current: nil)
        XCTAssertEqual(items, [.none(checked: true), .target(id: 1, title: "Kept", checked: false, children: [])])
    }

    func testAGroupCarriesItselfFirst() throws {
        let child = node(try target(11, "Leaf", parent: 10))
        let group = node(try target(10, "Group"), [child])
        let items = SessionTargetMenu.items(roots: [group], current: 10)
        XCTAssertEqual(items, [
            .none(checked: false),
            .target(id: 10, title: "Group", checked: false, children: [
                .target(id: 10, title: "Group", checked: true, children: []),
                .target(id: 11, title: "Leaf", checked: false, children: [])
            ])
        ])
    }
}
