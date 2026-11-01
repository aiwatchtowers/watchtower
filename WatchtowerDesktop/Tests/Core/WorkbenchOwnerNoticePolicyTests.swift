import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A board edit made on the phone reaches the database through the Go hub,
/// which records it as `db.ActorOwner` in `target_status_history` and never
/// calls the Desktop's in-process `onOwnerWrite`. The newest history row's
/// actor keeps the owner's own edit from coming back as a notice.
final class WorkbenchOwnerNoticePolicyTests: XCTestCase {
    typealias Policy = WorkbenchNotificationPolicy

    private var db: DatabaseQueue!

    override func setUp() async throws {
        db = try TestDatabase.create()
    }

    /// Two polls around `change`, the second one fed the owner-written
    /// targets exactly as `WorkbenchNotificationCenter.poll` does.
    private func notices(after change: (Database, Int64) throws -> Void) throws -> [WorkbenchNotice] {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let t = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task 1", status: "in_progress")
            let project = try XCTUnwrap(WorkbenchQueries.fetch(d, id: p))
            let previous = try WorkbenchQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            try change(d, t)
            var current = try WorkbenchQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            current.ownerTouched.formUnion(WorkbenchOwnerNoticePolicy.ownerWritten(
                newestActors: try WorkbenchQueries.newestStatusActors(d, projectID: p)
            ))
            return Policy.decide(previous: previous, current: current)
        }
    }

    func testAPhoneEditWithOwnerActorIsNotAnnounced() throws {
        // The hub's board handler: an unclaimed status write, recorded as the owner.
        let sent = try notices { d, t in
            try d.execute(sql: "UPDATE targets SET status = 'done' WHERE id = ?", arguments: [t])
        }
        XCTAssertTrue(sent.isEmpty, "the owner's own phone edit is not announced: \(sent.map(\.title))")
    }

    func testAnAgentChangeIsStillAnnounced() throws {
        let sent = try notices { d, t in
            try d.execute(sql: "UPDATE targets SET status = 'done', status_actor = 'agent' WHERE id = ?", arguments: [t])
        }
        XCTAssertEqual(sent.map(\.title), ["Task 1 done"])
    }

    func testOnlyTheNewestRowDecides() {
        XCTAssertFalse(WorkbenchOwnerNoticePolicy.shouldAnnounce(newestActor: "owner"))
        XCTAssertTrue(WorkbenchOwnerNoticePolicy.shouldAnnounce(newestActor: "agent"))
        XCTAssertTrue(WorkbenchOwnerNoticePolicy.shouldAnnounce(newestActor: "system"))
        XCTAssertTrue(WorkbenchOwnerNoticePolicy.shouldAnnounce(newestActor: nil), "no history row: the old rule decides")
        XCTAssertEqual(
            WorkbenchOwnerNoticePolicy.ownerWritten(newestActors: [1: "owner", 2: "agent", 3: "system"]),
            [.target(1)]
        )
    }

    /// `ownerActor` is Go's `db.ActorOwner`, read from the fixture Go's
    /// `TestActorsFixture` writes from its constants.
    func testActorLiteralMatchesGo() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/db/testdata/actors.json")
        let actors = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        XCTAssertEqual(actors["owner"], WorkbenchOwnerNoticePolicy.ownerActor)
    }
}
