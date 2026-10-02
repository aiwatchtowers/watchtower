import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class TargetWatchesViewModelTests: XCTestCase {

    private func makeWatch(_ db: Database, targetID: Int?, text: String) throws -> Int {
        try db.execute(sql: """
            INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                origin, instruction, enabled, linked_target_id)
            VALUES ('U1', ?, '', 'task', 'watching', 'medium', 'custom', 'watch', 1, ?)
            """, arguments: [text, targetID])
        return Int(db.lastInsertedRowID)
    }

    func testFetchForTargetScopesToTargetsWatches() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let t1 = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal one", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let t2 = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal two", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        try manager.dbPool.write { db in
            let w1 = try makeWatch(db, targetID: t1, text: "watch A")
            let w2 = try makeWatch(db, targetID: t2, text: "watch B")
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'a1', '2026-06-10T00:00:00Z')", arguments: [w1])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'a2', '2026-06-11T00:00:00Z')", arguments: [w1])
            try db.execute(sql: "INSERT INTO track_events (track_id, summary, created_at) VALUES (?, 'b1', '2026-06-12T00:00:00Z')", arguments: [w2])
        }
        let events = try manager.dbPool.read { db in
            try TrackEventQueries.fetchForTarget(db, targetID: t1)
        }
        XCTAssertEqual(events.map(\.summary), ["a2", "a1"], "only t1's watch events, newest-first")
    }

    /// `scanWatch` runs the scan via a CLI subprocess, which writes on its own
    /// SQLite connection — a same-process ValueObservation (as `start()` sets
    /// up) never sees those rows. This never calls `start()` at all, so it
    /// isolates the fix: the feed must refresh from `scanWatch` alone.
    func testScanWatchRefreshesFeedWithoutAnyObservationRunning() async throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let targetID = try await manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "goal", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        // Inlined instead of the `makeWatch` helper: that helper is an instance
        // method on this (@MainActor) test class, and the async `write` overload
        // requires a `@Sendable`, non-isolated closure — it cannot call back
        // into a MainActor-isolated method.
        let watchID = try await manager.dbPool.write { db -> Int in
            try db.execute(sql: """
                INSERT INTO tracks (assignee_user_id, text, context, category, ownership, priority,
                    origin, instruction, enabled, linked_target_id)
                VALUES ('U1', 'watch A', '', 'task', 'watching', 'medium', 'custom', 'watch', 1, ?)
                """, arguments: [targetID])
            return Int(db.lastInsertedRowID)
        }
        let fetchedTarget = try await manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID) }
        let target = try XCTUnwrap(fetchedTarget)
        let fetchedWatch = try await manager.dbPool.read { db in try TrackQueries.fetchByID(db, id: watchID) }
        let watch = try XCTUnwrap(fetchedWatch)

        let vm = TargetWatchesViewModel(
            target: target,
            dbManager: manager,
            scanService: TrackScanService(runner: FakeCLIRunner(stdout: Data("[]".utf8))),
            targetsViewModel: TargetsViewModel(dbManager: manager),
            scanCenter: TrackScanCenter()
        )
        XCTAssertTrue(vm.events.isEmpty)

        // Simulate the CLI subprocess having already written a new row (on its
        // own connection) by the time scanWatch's await returns.
        try await manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, created_at)
                VALUES (?, 'new update', '2026-07-01T00:00:00Z')
                """, arguments: [watchID])
        }

        await vm.scanWatch(watch, since: nil, label: "all history")

        XCTAssertEqual(vm.events.map(\.summary), ["new update"], "the feed must reflect the CLI's write without an active observation")
    }

    func testApplyActionMutatesTargetAndMarksApplied() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        defer { TestDatabase.cleanup(path: path) }

        let targetID = try manager.dbPool.write { db -> Int in
            try TargetQueries.create(db, text: "ship it", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let (watchID, eventID) = try manager.dbPool.write { db -> (Int, Int) in
            let w = try makeWatch(db, targetID: targetID, text: "watch ship")
            try db.execute(sql: """
                INSERT INTO track_events (track_id, summary, proposed_action, action_status)
                VALUES (?, 'done', ?, 'pending')
                """, arguments: [w, #"{"type":"update_status","reason":"shipped","status":"done"}"#])
            return (w, Int(db.lastInsertedRowID))
        }
        _ = watchID

        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: targetID) })
        let vm = TargetWatchesViewModel(
            target: target,
            dbManager: manager,
            scanService: TrackScanService(runner: FakeCLIRunner(stdout: Data("[]".utf8))),
            targetsViewModel: TargetsViewModel(dbManager: manager),
            scanCenter: TrackScanCenter()
        )
        let event = try XCTUnwrap(manager.dbPool.read { db in
            try TrackEvent.fetchOne(db, sql: "SELECT * FROM track_events WHERE id = ?", arguments: [eventID])
        })
        vm.applyAction(for: event)

        let status = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = ?", arguments: [targetID])
        }
        XCTAssertEqual(status, "done")
        let evStatus = try manager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT action_status FROM track_events WHERE id = ?", arguments: [eventID])
        }
        XCTAssertEqual(evStatus, "applied")
    }
}
