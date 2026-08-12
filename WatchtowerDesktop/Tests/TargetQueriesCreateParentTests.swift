import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop

final class TargetQueriesCreateParentTests: XCTestCase {

    func testCreate_PersistsParentID() throws {
        let queue = try TestDatabase.create()
        let (parentID, childID) = try queue.write { db -> (Int, Int) in
            let parent = try TargetQueries.create(
                db,
                text: "parent",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28"
            )
            let child = try TargetQueries.create(
                db,
                text: "child",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28",
                parentId: parent
            )
            return (parent, child)
        }

        let child = try queue.read { db in
            try TargetQueries.fetchByID(db, id: childID)
        }
        XCTAssertEqual(child?.parentId, parentID)
    }

    func testCreate_NoParent_LeavesParentIDNil() throws {
        let queue = try TestDatabase.create()
        let newID = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "top-level",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28"
            )
        }
        let target = try queue.read { db in
            try TargetQueries.fetchByID(db, id: newID)
        }
        XCTAssertNil(target?.parentId)
    }

    func testFetchAll_ParentIDFilter_ReturnsOnlyChildren() throws {
        let queue = try TestDatabase.create()
        let parentID = try queue.write { db -> Int in
            let parent = try TargetQueries.create(
                db,
                text: "parent",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28"
            )
            _ = try TargetQueries.create(
                db,
                text: "child-a",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28",
                parentId: parent
            )
            _ = try TargetQueries.create(
                db,
                text: "child-b",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28",
                parentId: parent
            )
            // An unrelated top-level target that must not appear in the result.
            _ = try TargetQueries.create(
                db,
                text: "other",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28"
            )
            return parent
        }

        let children = try queue.read { db in
            try TargetQueries.fetchAll(db, filter: TargetFilter(parentID: parentID))
        }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(Set(children.map(\.text)), ["child-a", "child-b"])
        XCTAssertTrue(children.allSatisfy { $0.parentId == parentID })
    }
}
