import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// A parent or a link endpoint deleted elsewhere (the agent, the CLI, a
/// second window) must fail as `TargetNotFoundError` naming that target —
/// not as SQLite's bare "FOREIGN KEY constraint failed" — and write nothing.
final class TargetQueriesMissingEndpointTests: XCTestCase {

    private func createTarget(_ db: Database, text: String, parent: Int? = nil) throws -> Int {
        try TargetQueries.create(db, text: text, periodStart: "2026-09-30", periodEnd: "2026-09-30", parentId: parent)
    }

    private func count(_ db: Database, _ table: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }

    func testCreate_UnderADeletedParent_ThrowsNotFoundNamingTheParent() throws {
        let queue = try TestDatabase.create()
        let parent = try queue.write { db -> Int in
            let id = try self.createTarget(db, text: "parent")
            try TargetQueries.delete(db, id: id)
            return id
        }

        XCTAssertThrowsError(try queue.write { try self.createTarget($0, text: "child", parent: parent) }) {
            XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: parent))
        }
        XCTAssertEqual(try queue.read { try self.count($0, "targets") }, 0, "nothing created")
    }

    func testUpdateParent_ToADeletedParent_ThrowsNotFoundNamingTheParent() throws {
        let queue = try TestDatabase.create()
        let (child, oldParent, gone) = try queue.write { db -> (Int, Int, Int) in
            let oldParent = try self.createTarget(db, text: "old parent")
            let child = try self.createTarget(db, text: "child", parent: oldParent)
            let gone = try self.createTarget(db, text: "gone")
            try TargetQueries.delete(db, id: gone)
            return (child, oldParent, gone)
        }

        XCTAssertThrowsError(try queue.write { try TargetQueries.updateParent($0, id: child, parentID: gone) }) {
            XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: gone))
        }
        XCTAssertEqual(try queue.read { try TargetQueries.parentID($0, of: child) }, oldParent, "the move wrote nothing")
    }

    func testCreateLink_WithADeletedEndpoint_ThrowsNotFoundNamingIt() throws {
        let queue = try TestDatabase.create()
        let (live, gone) = try queue.write { db -> (Int, Int) in
            let live = try self.createTarget(db, text: "live")
            let gone = try self.createTarget(db, text: "gone")
            try TargetQueries.delete(db, id: gone)
            return (live, gone)
        }

        // Deleted link target.
        XCTAssertThrowsError(try queue.write {
            try TargetQueries.createLink($0, sourceID: live, targetID: gone, relation: "blocks")
        }) { XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: gone)) }
        // Deleted source.
        XCTAssertThrowsError(try queue.write {
            try TargetQueries.createLink($0, sourceID: gone, targetID: live, relation: "blocks")
        }) { XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: gone)) }
        // Deleted source of an external-ref link (no target endpoint at all).
        XCTAssertThrowsError(try queue.write {
            try TargetQueries.createLink(
                $0, sourceID: gone, targetID: nil, externalRef: "jira:ACME-1", relation: "related", createdBy: "ai"
            )
        }) { XCTAssertEqual($0 as? TargetNotFoundError, TargetNotFoundError(id: gone)) }

        XCTAssertEqual(try queue.read { try self.count($0, "target_links") }, 0)
    }

    func testCreateLink_ToATargetAndToAnExternalRef_Writes() throws {
        let queue = try TestDatabase.create()
        let (source, other) = try queue.write { db -> (Int, Int) in
            (try self.createTarget(db, text: "source"), try self.createTarget(db, text: "other"))
        }

        try queue.write { db in
            try TargetQueries.createLink(db, sourceID: source, targetID: other, relation: "blocks", createdBy: "ai")
            try TargetQueries.createLink(
                db, sourceID: source, targetID: nil, externalRef: "jira:ACME-1", relation: "related", createdBy: "ai"
            )
        }
        let links = try queue.read { try TargetQueries.fetchLinks($0, targetID: source, direction: .outbound) }
        XCTAssertEqual(Set(links.map(\.relation)), ["blocks", "related"])
    }
}
