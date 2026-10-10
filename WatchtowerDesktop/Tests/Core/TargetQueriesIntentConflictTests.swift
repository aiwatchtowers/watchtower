import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

/// The workbench panel's description save (`updateIntent(_:id:intent:ifUnchangedFrom:)`):
/// the write itself checks the description the editor opened with, so an
/// agent's `update_target` landing between the board's poll and the save is
/// never overwritten.
final class TargetQueriesIntentConflictTests: XCTestCase {

    private func createTarget(_ db: Database, intent: String = "") throws -> Int {
        let id = try TargetQueries.create(
            db,
            text: "t",
            level: "day",
            periodStart: "2026-09-30",
            periodEnd: "2026-09-30",
            sourceType: "manual",
            sourceID: ""
        )
        try db.execute(sql: "UPDATE targets SET intent = ?, updated_at = '2026-01-01T00:00:00Z' WHERE id = ?",
                       arguments: [intent, id])
        return id
    }

    private func stored(_ queue: DatabaseQueue, _ id: Int) throws -> (intent: String, updatedAt: String) {
        let target = try XCTUnwrap(try queue.read { try TargetQueries.fetchByID($0, id: id) })
        return (target.intent, target.updatedAt)
    }

    func testWritesOverTheDescriptionItOpenedWith() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try self.createTarget($0, intent: "Opened") }

        try queue.write { try TargetQueries.updateIntent($0, id: id, intent: "Owner's text", ifUnchangedFrom: "Opened") }

        let after = try stored(queue, id)
        XCTAssertEqual(after.intent, "Owner's text")
        XCTAssertNotEqual(after.updatedAt, "2026-01-01T00:00:00Z")
    }

    func testANewerDescriptionThrowsAConflictAndIsKept() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try self.createTarget($0, intent: "Agent's newer text") }

        XCTAssertThrowsError(
            try queue.write { try TargetQueries.updateIntent($0, id: id, intent: "Owner's text", ifUnchangedFrom: "") }
        ) { error in
            XCTAssertEqual(error as? TargetIntentConflictError, TargetIntentConflictError(id: id))
        }
        let after = try stored(queue, id)
        XCTAssertEqual(after.intent, "Agent's newer text")
        XCTAssertEqual(after.updatedAt, "2026-01-01T00:00:00Z", "nothing was written")
    }

    /// The agent wrote the very text the owner typed: nothing is lost, so
    /// it is no conflict.
    func testANewerDescriptionEqualToTheDraftIsNoConflict() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try self.createTarget($0, intent: "Same text") }

        XCTAssertNoThrow(
            try queue.write { try TargetQueries.updateIntent($0, id: id, intent: "Same text", ifUnchangedFrom: "") }
        )
        XCTAssertEqual(try stored(queue, id).intent, "Same text")
    }

    func testADeletedTargetThrowsNotFound() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { db -> Int in
            let id = try self.createTarget(db)
            try TargetQueries.delete(db, id: id)
            return id
        }

        XCTAssertThrowsError(
            try queue.write { try TargetQueries.updateIntent($0, id: id, intent: "why", ifUnchangedFrom: "") }
        ) { error in
            XCTAssertEqual(error as? TargetNotFoundError, TargetNotFoundError(id: id))
        }
    }

    /// The unconditional mutator (the Targets tab, the target chat's
    /// `update_intent` action) keeps writing whatever is stored.
    func testTheUnconditionalMutatorStillOverwrites() throws {
        let queue = try TestDatabase.create()
        let id = try queue.write { try self.createTarget($0, intent: "Agent's newer text") }

        try queue.write { try TargetQueries.updateIntent($0, id: id, intent: "Owner's text") }

        XCTAssertEqual(try stored(queue, id).intent, "Owner's text")
    }

    func testConflictErrorNamesTheTarget() {
        let text = TargetIntentConflictError(id: 42).localizedDescription
        XCTAssertTrue(text.contains("#42"), text)
        XCTAssertTrue(text.contains("changed while you were editing"), text)
    }
}
