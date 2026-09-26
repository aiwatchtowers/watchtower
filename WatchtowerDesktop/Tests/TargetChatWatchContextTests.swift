import XCTest
import GRDB
import WatchtowerCore
@testable import WatchtowerDesktop
import WatchtowerTestSupport

@MainActor
final class TargetChatWatchContextTests: XCTestCase {
    static let trackEventsSQL = TargetWatchesViewModelTests.trackEventsSQL

    func testWatchActivityBlockPresentWhenEventsExistAbsentOtherwise() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }
        try manager.dbPool.write { db in try db.execute(sql: Self.trackEventsSQL) }

        let targetID = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID) })

        // No watches yet → empty block.
        let empty = TargetChatViewModel.watchActivityBlock(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(empty.isEmpty, "no watch events → no block")

        // Add a watch + an event → block appears with the summary.
        try manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                    origin, instruction, enabled, linked_target_id)
                VALUES ('U1', 'watch', '', 'task', 'watching', 'medium', 'custom', 'i', 1, ?)
                """, arguments: [targetID])
            let w = Int(db.lastInsertedRowID)
            try db.execute(sql: "INSERT INTO track_events (track_id, summary) VALUES (?, 'refund approved')", arguments: [w])
        }
        let block = TargetChatViewModel.watchActivityBlock(target: target, dbPool: manager.dbPool)
        XCTAssertTrue(block.contains("WATCH ACTIVITY"))
        XCTAssertTrue(block.contains("refund approved"))
    }
}
