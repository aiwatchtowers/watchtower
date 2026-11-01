import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A board edit made on the phone reaches the database through the Go hub,
/// which records it as `db.ActorOwner` in `target_status_history` and never
/// calls the Desktop's in-process `onOwnerWrite`. The newest history row's
/// actor (a rollup row: its cause's) keeps the owner's own edit from coming
/// back as a notice.
final class WorkbenchOwnerNoticePolicyTests: XCTestCase {
    typealias Policy = WorkbenchNotificationPolicy

    private var db: DatabaseQueue!

    override func setUp() async throws {
        db = try TestDatabase.create()
    }

    /// A Feature → Task chain (two targets: under the coalescing threshold),
    /// two `activitySnapshot` reads around `change` (given the leaf), and the
    /// titles the policy sends between them.
    private func notices(after change: (Database, Int64) throws -> Void) throws -> [String] {
        try db.write { d in
            let p = try TestDatabase.insertWorkbench(d)
            let parent = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Feature")
            let leaf = try TestDatabase.insertWorkbenchTarget(d, projectID: p, text: "Task", parentID: parent)
            let project = try XCTUnwrap(WorkbenchQueries.fetch(d, id: p))
            let previous = try WorkbenchQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            try change(d, leaf)
            let current = try WorkbenchQueries.activitySnapshot(d, project: project, afterAgentCommentID: 0)
            XCTAssertEqual(try String.fetchOne(d, sql: "SELECT status FROM targets WHERE id = ?", arguments: [parent]), "done",
                           "PROJ-05: the chain rolled up")
            return Policy.decide(previous: previous, current: current).map(\.title)
        }
    }

    func testAPhoneEditWithOwnerActorIsNotAnnounced() throws {
        // The hub's board handler: an unclaimed status write, recorded as the
        // owner; the parent it closed is recorded as `system` right after.
        let sent = try notices { d, leaf in
            try d.execute(sql: "UPDATE targets SET status = 'done' WHERE id = ?", arguments: [leaf])
        }
        XCTAssertEqual(sent, [], "neither the owner's phone edit nor the parent it rolled up is announced")
    }

    func testAnAgentChangeIsStillAnnounced() throws {
        let sent = try notices { d, leaf in
            try d.execute(sql: "UPDATE targets SET status = 'done', status_actor = 'agent' WHERE id = ?", arguments: [leaf])
        }
        XCTAssertEqual(sent, ["Feature done", "Task done"],
                       "the agent's close and the parent it rolled up are announced")
    }

    /// A rollup row takes its cause's actor only within the same statement:
    /// an earlier owner row from another second does not silence it.
    func testARollupLaterThanTheOwnersRowIsAnnounced() throws {
        let sent = try notices { d, leaf in
            try d.execute(sql: "UPDATE targets SET status = 'done' WHERE id = ?", arguments: [leaf])
            try d.execute(sql: "UPDATE target_status_history SET changed_at = '2026-01-01T00:00:00Z' WHERE actor = 'owner'")
        }
        XCTAssertEqual(sent, ["Feature done"])
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
