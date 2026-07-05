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
}
