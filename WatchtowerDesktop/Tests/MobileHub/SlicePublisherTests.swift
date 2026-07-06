import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class SlicePublisherTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var state: HubSyncState!
    private var transport: InMemoryCloudTransport!
    private var publisher: SlicePublisher!

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        state = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
        publisher = SlicePublisher(dbPool: dbPool, state: state, transport: transport)
    }

    override func tearDownWithError() throws {
        publisher = nil
        transport = nil
        state = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    func testPublishOncePushesFixtureRows() async throws {
        // Guard: every SliceKind must have a window — a kind missing from
        // sliceSQL would silently never sync.
        XCTAssertEqual(Set(SlicePublisher.sliceSQL.keys), Set(SliceKind.allCases))

        try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Ship slice publisher")
            try TestDatabase.insertTarget(db, text: "Write the tests")
            try TestDatabase.insertInboxItem(db)
        }

        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 3)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertTrue(result.skipped.isEmpty)

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(
            Set(batch.changed.map(\.recordName)),
            ["target-1", "target-2", "inbox_item-1"]
        )
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testSecondPublishWithNoDBChangePushesNothing() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertTarget(db)
            try TestDatabase.insertInboxItem(db)
        }
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 2)
        let token = try await transport.changes(in: .data, since: nil).newToken

        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.pushed, 0)
        XCTAssertEqual(second.deleted, 0)
        XCTAssertTrue(second.skipped.isEmpty)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertTrue(delta.changed.isEmpty)
        XCTAssertTrue(delta.deletedRecordNames.isEmpty)
    }

    func testDeletedRowEmitsTransportDeleteAndDropsHash() async throws {
        let doomedID = try await dbPool.write { db in
            let id = try TestDatabase.insertTarget(db, text: "Soon gone")
            _ = try TestDatabase.insertTarget(db, text: "Stays")
            return id
        }
        _ = try await publisher.publishOnce()
        let token = try await transport.changes(in: .data, since: nil).newToken

        try await dbPool.write { db in
            try db.execute(sql: "DELETE FROM targets WHERE id = ?", arguments: [doomedID])
        }
        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 0)
        XCTAssertEqual(result.deleted, 1)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertEqual(delta.deletedRecordNames, ["target-\(doomedID)"])
        XCTAssertTrue(delta.changed.isEmpty)
        XCTAssertNil(try state.hashes(forKind: .target)["target-\(doomedID)"])
    }

    func testUpdatedRowIsRepushedExactly() async throws {
        let updatedID = try await dbPool.write { db in
            let id = try TestDatabase.insertTarget(db, text: "Old text")
            _ = try TestDatabase.insertTarget(db, text: "Untouched")
            try TestDatabase.insertInboxItem(db)
            return id
        }
        _ = try await publisher.publishOnce()
        let token = try await transport.changes(in: .data, since: nil).newToken

        try await dbPool.write { db in
            try db.execute(sql: "UPDATE targets SET text = 'New text' WHERE id = ?", arguments: [updatedID])
        }
        let result = try await publisher.publishOnce()

        XCTAssertEqual(result.pushed, 1)
        XCTAssertEqual(result.deleted, 0)
        let delta = try await transport.changes(in: .data, since: token)
        XCTAssertEqual(delta.changed.map(\.recordName), ["target-\(updatedID)"])
        XCTAssertTrue(delta.deletedRecordNames.isEmpty)
    }

    /// Fix 4 regression: a mid-cycle wipeSyncState must cause publishOnce to abort
    /// before recording hashes for the new account, so the next cycle re-pushes all records.
    func testWipeBetweenCyclesTriggersFullRepushOnNextCycle() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertTarget(db, text: "Alpha")
            try TestDatabase.insertTarget(db, text: "Beta")
        }

        // First cycle: hashes recorded, records pushed.
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 2)

        // Simulate account reset: wipe bumps generation.
        let genBefore = try state.generation()
        try state.wipeSyncState()
        let genAfter = try state.generation()
        XCTAssertGreaterThan(genAfter, genBefore, "wipeSyncState must bump generation")

        // After wipe, hashes are gone — next publishOnce sees all records as new.
        let second = try await publisher.publishOnce()
        XCTAssertEqual(second.pushed, 2, "after wipeSyncState, all records must be re-pushed")
    }

    // Exercises the two calendar_events-specific paths in publishOnce:
    //   1. rowID(.string) — calendar_events.id is TEXT PRIMARY KEY
    //   2. datetime(start_time) window — only events within −1d..+14d from now
    // Note: insertCalendarEvent's DEFAULT startTime is in 2023 — outside the
    // publish window — so events inserted with defaults never sync (pushed == 0);
    // always pass explicit run-time-relative timestamps here.
    func testCalendarEventTextIdAndDatetimeWindow() async throws {
        let inWindowID  = "cal_future_001"
        let outWindowID = "cal_past_030"

        // Computed from Date() so the test never rots against the SQL's live
        // datetime('now'). ISO8601DateFormatter emits the schema's required
        // 'T'-separated format with a 'Z' suffix.
        let iso = ISO8601DateFormatter()
        // +8h — inside the −1d..+14d window
        let inWindowStart = iso.string(from: Date().addingTimeInterval(8 * 3600))
        let inWindowEnd   = iso.string(from: Date().addingTimeInterval(9 * 3600))
        // −30d — outside the window
        let outWindowStart = iso.string(from: Date().addingTimeInterval(-30 * 24 * 3600))
        let outWindowEnd   = iso.string(from: Date().addingTimeInterval(-30 * 24 * 3600 + 3600))

        try await dbPool.write { db in
            try TestDatabase.insertCalendarEvent(
                db,
                id: inWindowID,
                startTime: inWindowStart,
                endTime: inWindowEnd
            )
            try TestDatabase.insertCalendarEvent(
                db,
                id: outWindowID,
                startTime: outWindowStart,
                endTime: outWindowEnd
            )
        }

        let result = try await publisher.publishOnce()
        XCTAssertEqual(result.pushed, 1, "only the in-window event should be pushed")
        XCTAssertEqual(result.deleted, 0)
        XCTAssertTrue(result.skipped.isEmpty)

        let batch = try await transport.changes(in: .data, since: nil)
        let names = Set(batch.changed.map(\.recordName))
        XCTAssertTrue(
            names.contains("calendar_event-\(inWindowID)"),
            "in-window event must appear as calendar_event-\(inWindowID) (TEXT id branch)"
        )
        XCTAssertFalse(
            names.contains("calendar_event-\(outWindowID)"),
            "out-of-window event must be excluded by the datetime() filter"
        )
    }
}
