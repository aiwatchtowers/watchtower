import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class RelayProcessorActionTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var sidecar: HubSyncState!
    private var transport: InMemoryCloudTransport!
    private var processor: RelayProcessor!
    /// Injected clock — 2026-06-21T02:40:00Z — so task_create periods are deterministic.
    private let fixedNow = Date(timeIntervalSince1970: 1_782_009_600)

    override func setUpWithError() throws {
        let (manager, path) = try TestDatabase.createDatabaseManager()
        dbPath = path
        dbPool = manager.dbPool
        sidecar = try HubSyncState.inMemory()
        transport = InMemoryCloudTransport()
        processor = makeProcessor()
    }

    override func tearDownWithError() throws {
        processor = nil
        transport = nil
        sidecar = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    private func makeProcessor() -> RelayProcessor {
        let fixed = fixedNow
        return RelayProcessor(
            dbPool: dbPool,
            transport: transport,
            sidecar: sidecar,
            aiService: MockClaudeService()
        ) { fixed }
    }

    // MARK: - Helpers

    /// Saves a pending action record to the relay zone, as mobile would.
    @discardableResult
    private func enqueue(
        _ kind: ActionKind,
        id: String,
        entityID: String?,
        params: [String: JSONValue] = [:]
    ) async throws -> String {
        let action = ActionRequestPayload(id: id, kind: kind, entityID: entityID, params: params, createdAt: Date())
        try await transport.save([try CloudRecordFactory.record(for: action, modifiedAt: Date())])
        return action.recordName
    }

    /// Latest relay-zone state of the given action record, decoded.
    private func statusPayload(recordName: String) async throws -> ActionRequestPayload? {
        let batch = try await transport.changes(in: .relay, since: nil)
        guard let record = batch.changed.first(where: { $0.recordName == recordName }) else { return nil }
        return try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
    }

    /// Local-timezone yyyy-MM-dd, matching the processor's task_create periods
    /// and TargetQueries.snooze's stored format.
    private func dayString(from date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt.string(from: date)
    }

    // MARK: - Tests

    func testInboxResolveAppliesWritesBackAndSkipsDuplicateDelivery() async throws {
        try await dbPool.write { db in try TestDatabase.insertInboxItem(db) } // id 1
        let recordName = try await enqueue(.inboxResolve, id: "a1", entityID: "1")

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 1)
        let (status, reason) = try await dbPool.read { db -> (String, String) in
            let row = try Row.fetchOne(
                db, sql: "SELECT status, resolved_reason FROM inbox_items WHERE id = 1"
            )
            return (row?["status"] ?? "", row?["resolved_reason"] ?? "")
        }
        XCTAssertEqual(status, "resolved")
        XCTAssertEqual(reason, "Resolved from mobile")
        let payload = try await statusPayload(recordName: recordName)
        XCTAssertEqual(payload?.status, .applied)
        XCTAssertNil(payload?.errorMessage)

        // Duplicate delivery of the same pending record (spec Section 4):
        // the processed-set must skip it even though it decodes as pending.
        _ = try await enqueue(.inboxResolve, id: "a1", entityID: "1")
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE inbox_items SET status = 'pending' WHERE id = 1")
        }
        let second = try await processor.processOnce()
        XCTAssertEqual(second, 0)
        let after = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM inbox_items WHERE id = 1")
        }
        XCTAssertEqual(after, "pending", "duplicate delivery must not re-apply the action")
    }

    func testTargetSnoozeParsesISODateAndApplies() async throws {
        let targetID = try await dbPool.write { db in try TestDatabase.insertTarget(db) }
        let until = "2026-07-10T12:00:00Z"
        let recordName = try await enqueue(
            .targetSnooze,
            id: "a2",
            entityID: String(targetID),
            params: ["snooze_until": .string(until)]
        )

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 1)
        let (status, snoozeUntil) = try await dbPool.read { db -> (String, String) in
            let row = try Row.fetchOne(
                db, sql: "SELECT status, snooze_until FROM targets WHERE id = ?", arguments: [targetID]
            )
            return (row?["status"] ?? "", row?["snooze_until"] ?? "")
        }
        XCTAssertEqual(status, "snoozed")
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: until))
        XCTAssertEqual(snoozeUntil, dayString(from: instant))
        let payload = try await statusPayload(recordName: recordName)
        XCTAssertEqual(payload?.status, .applied)
    }

    func testFailedActionReportsErrorAndBatchContinues() async throws {
        try await dbPool.write { db in try TestDatabase.insertInboxItem(db) } // id 1
        let badName = try await enqueue(.inboxDismiss, id: "bad", entityID: "999")
        let goodName = try await enqueue(.inboxDismiss, id: "good", entityID: "1")

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 1, "the valid action after the failed one must still apply")
        let bad = try await statusPayload(recordName: badName)
        XCTAssertEqual(bad?.status, .failed)
        XCTAssertFalse(bad?.errorMessage?.isEmpty ?? true, "failed action must carry a non-empty errorMessage")
        let good = try await statusPayload(recordName: goodName)
        XCTAssertEqual(good?.status, .applied)
        let status = try await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT status FROM inbox_items WHERE id = 1")
        }
        XCTAssertEqual(status, "dismissed")
    }

    func testTaskCreateInsertsTargetForToday() async throws {
        let recordName = try await enqueue(
            .taskCreate,
            id: "a4",
            entityID: nil,
            params: ["text": .string("Buy milk")]
        )

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 1)
        let (text, periodStart, periodEnd) = try await dbPool.read { db -> (String, String, String) in
            let row = try Row.fetchOne(db, sql: "SELECT text, period_start, period_end FROM targets")
            return (row?["text"] ?? "", row?["period_start"] ?? "", row?["period_end"] ?? "")
        }
        XCTAssertEqual(text, "Buy milk")
        let today = dayString(from: fixedNow)
        XCTAssertEqual(periodStart, today)
        XCTAssertEqual(periodEnd, today)
        let payload = try await statusPayload(recordName: recordName)
        XCTAssertEqual(payload?.status, .applied)
    }

    func testTokenPersistedSoSecondCycleSeesOnlyNewActions() async throws {
        try await dbPool.write { db in
            try TestDatabase.insertInboxItem(db) // id 1
            try TestDatabase.insertInboxItem(db, messageTS: "1700000000.000200") // id 2
        }
        _ = try await enqueue(.inboxDismiss, id: "a5", entityID: "1")
        let first = try await processor.processOnce()
        XCTAssertEqual(first, 1)

        _ = try await enqueue(.inboxDismiss, id: "a6", entityID: "2")
        let second = try await processor.processOnce()
        XCTAssertEqual(second, 1, "second cycle must see only the new action")

        // The token lives in the sidecar, not the processor: a fresh instance
        // over the same sidecar resumes past everything already processed.
        let fresh = try await makeProcessor().processOnce()
        XCTAssertEqual(fresh, 0)
    }
}
