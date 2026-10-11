import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// Board #499: Work on It moves a `todo` workbench task to `in_progress` as
/// the owner's write (`WorkbenchQueries.markInProgressOnWorkOn`), and nothing
/// else.
final class WorkbenchWorkOnStatusTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func status(_ d: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(d, sql: "SELECT status FROM targets WHERE id = ?", arguments: [id])
    }

    func testATodoTaskMovesToInProgressAsTheOwners() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let id = try TestDatabase.insertWorkbenchTarget(d, projectID: p)

            XCTAssertEqual(try WorkbenchQueries.markInProgressOnWorkOn(d, targetID: id), [])
            XCTAssertEqual(try status(d, id), "in_progress")
            let last = try XCTUnwrap(TargetQueries.statusHistory(d, targetID: id).last)
            XCTAssertEqual(last.fromStatus, "todo")
            XCTAssertEqual(last.toStatus, "in_progress")
            XCTAssertEqual(last.actor, "owner")
        }
    }

    /// The parent the rollup moves comes back, so the caller reports it as
    /// the owner's doing (no notice), as the board's own status writer does.
    func testReturnsTheParentsTheRollupMoved() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let group = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Group")
            let child = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task", parentID: group)
            _ = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Other", parentID: group)

            XCTAssertEqual(try WorkbenchQueries.markInProgressOnWorkOn(d, targetID: child), [group])
            XCTAssertEqual(try status(d, group), "in_progress")
            XCTAssertEqual(try TargetQueries.statusHistory(d, targetID: group).last?.actor, "system")
        }
    }

    func testEveryOtherStatusIsLeftAlone() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            for current in ["in_progress", "in_review", "blocked", "done", "dismissed"] {
                let id = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: current, status: current)
                let rows = try TargetQueries.statusHistory(d, targetID: id).count

                XCTAssertNil(try WorkbenchQueries.markInProgressOnWorkOn(d, targetID: id), current)
                XCTAssertEqual(try status(d, id), current)
                XCTAssertEqual(try TargetQueries.statusHistory(d, targetID: id).count, rows, current)
            }
        }
    }

    /// A group's status follows its sub-targets (PROJ-05): Work on It on a
    /// group writes nothing, even while it is still `todo`.
    func testAGroupIsNeverWritten() throws {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let group = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Group")
            let child = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task", parentID: group)

            XCTAssertNil(try WorkbenchQueries.markInProgressOnWorkOn(d, targetID: group))
            XCTAssertEqual(try status(d, group), "todo")
            XCTAssertEqual(try status(d, child), "todo")
        }
    }

    func testAPersonalOrMissingTargetWritesNothing() throws {
        try db.write { d in
            let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
            let personal = try TargetQueries.create(d, text: "personal", level: "day",
                                                    periodStart: today, periodEnd: today)

            XCTAssertNil(try WorkbenchQueries.markInProgressOnWorkOn(d, targetID: Int64(personal)))
            XCTAssertEqual(try status(d, Int64(personal)), "todo")
            XCTAssertNil(try WorkbenchQueries.markInProgressOnWorkOn(d, targetID: 9_999))
        }
    }
}
