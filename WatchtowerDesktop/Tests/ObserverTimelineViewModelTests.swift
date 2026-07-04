import XCTest
import GRDB
@testable import WatchtowerDesktop

@MainActor
final class ObserverTimelineViewModelTests: XCTestCase {

    /// Mirrors the Go-side observers/observer_events DDL (same as
    /// ObserverQueriesTests); TestDatabase.schema does not include these tables.
    private static let observerTablesSQL = """
        CREATE TABLE observers (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            entity_type TEXT NOT NULL DEFAULT 'target',
            entity_id INTEGER NOT NULL,
            name TEXT NOT NULL DEFAULT '',
            instruction TEXT NOT NULL DEFAULT '',
            enabled INTEGER NOT NULL DEFAULT 1,
            last_run_at TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE observer_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            observer_id INTEGER NOT NULL,
            entity_type TEXT NOT NULL DEFAULT 'target',
            entity_id INTEGER NOT NULL,
            summary TEXT NOT NULL DEFAULT '',
            detail TEXT NOT NULL DEFAULT '',
            source_type TEXT NOT NULL DEFAULT '',
            source_id TEXT NOT NULL DEFAULT '',
            source_refs TEXT NOT NULL DEFAULT '[]',
            decision TEXT NOT NULL DEFAULT '',
            proposed_action TEXT NOT NULL DEFAULT '',
            action_status TEXT NOT NULL DEFAULT 'none',
            read_at TEXT,
            created_at TEXT NOT NULL DEFAULT ''
        );
        """

    private func makeHarness(
        withObserverTables: Bool = true
    ) throws -> (manager: DatabaseManager, path: String, target: Target, timeline: ObserverTimelineViewModel) {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        if withObserverTables {
            try manager.dbPool.write { db in try db.execute(sql: Self.observerTablesSQL) }
        }
        let id = try manager.dbPool.write { db in
            try TargetQueries.create(db, text: "watched", periodStart: "2026-06-01", periodEnd: "2026-06-30")
        }
        let target = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: id) })
        let timeline = ObserverTimelineViewModel(
            target: target,
            dbManager: manager,
            targetsViewModel: TargetsViewModel(dbManager: manager),
            observeService: TargetObserveService(runner: FakeCLIRunner())
        )
        return (manager, path, target, timeline)
    }

    /// Two sequentially approved add_sub_item actions must BOTH persist: the
    /// executor's sub-item path is a whole-JSON read-modify-write, so applying
    /// against the init-time target snapshot would clobber the first write.
    func testApplyTwoAddSubItemActions_BothPersist() throws {
        let (manager, path, target, timeline) = try makeHarness()
        defer { TestDatabase.cleanup(path: path) }

        try manager.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO observer_events (observer_id, entity_id, summary, proposed_action, action_status)
                VALUES
                  (1, ?, 'first',  '{"type":"add_sub_item","reason":"r1","text":"first item"}',  'pending'),
                  (1, ?, 'second', '{"type":"add_sub_item","reason":"r2","text":"second item"}', 'pending')
                """, arguments: [target.id, target.id])
        }
        let events = try manager.dbPool.read { db in
            try ObserverQueries.fetchEvents(db, entityId: target.id)
        }
        XCTAssertEqual(events.count, 2)

        timeline.applyAction(for: events[0])
        timeline.applyAction(for: events[1])

        XCTAssertNil(timeline.errorMessage)
        let after = try XCTUnwrap(manager.dbPool.read { db in try TargetQueries.fetchByID(db, id: target.id) })
        XCTAssertEqual(after.decodedSubItems.map(\.text).sorted(), ["first item", "second item"])
        let statuses = try manager.dbPool.read { db in
            try String.fetchAll(db, sql: "SELECT action_status FROM observer_events ORDER BY id")
        }
        XCTAssertEqual(statuses, ["applied", "applied"])
    }

    // MARK: - CRUD error surfacing (no observers table → write must fail loudly)

    func testCreateObserverFailureSetsErrorMessage() throws {
        let (_, path, _, timeline) = try makeHarness(withObserverTables: false)
        defer { TestDatabase.cleanup(path: path) }

        timeline.createObserver(name: "n", instruction: "i")
        XCTAssertNotNil(timeline.errorMessage)
    }

    func testUpdateToggleDeleteObserverFailuresSetErrorMessage() throws {
        let (_, path, _, timeline) = try makeHarness(withObserverTables: false)
        defer { TestDatabase.cleanup(path: path) }
        let ghost = try makeGhostObserver()

        timeline.errorMessage = nil
        timeline.updateObserver(ghost, name: "n2", instruction: "i2")
        XCTAssertNotNil(timeline.errorMessage)

        timeline.errorMessage = nil
        timeline.toggleObserver(ghost)
        XCTAssertNotNil(timeline.errorMessage)

        timeline.errorMessage = nil
        timeline.deleteObserver(ghost)
        XCTAssertNotNil(timeline.errorMessage)
    }

    /// Builds a detached Observer row value (never persisted) for failure-path calls.
    private func makeGhostObserver() throws -> Observer {
        let queue = try DatabaseQueue()
        return try queue.write { db in
            try db.execute(sql: Self.observerTablesSQL)
            try ObserverQueries.create(db, entityId: 1, name: "ghost", instruction: "x")
            return try XCTUnwrap(try ObserverQueries.fetchForEntity(db, entityId: 1).first)
        }
    }
}
