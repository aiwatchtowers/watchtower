import GRDB
import XCTest
@testable import WatchtowerDesktop
@testable import WatchtowerKit
import WatchtowerTestSupport
import WatchtowerCore

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

    func testTargetSnoozeAcceptsFractionalSecondsISO8601() async throws {
        let targetID = try await dbPool.write { db in try TestDatabase.insertTarget(db) }
        let until = "2026-07-10T12:00:00.500Z"
        let recordName = try await enqueue(
            .targetSnooze,
            id: "a2b",
            entityID: String(targetID),
            params: ["snooze_until": .string(until)]
        )

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 1)
        let payload = try await statusPayload(recordName: recordName)
        XCTAssertEqual(payload?.status, .applied, "fractional-seconds ISO8601 must parse as .applied, not .failed")
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

    /// The four situation actions land in `SituationQueries` exactly like the
    /// desktop's own dashboard buttons: done stamps `user_done`, dismiss
    /// stamps `user_dismissed`, snooze stores the raw ISO string, and
    /// keep-open clears ONLY the suggested-resolution mark (DASH-07 — status
    /// stays open).
    func testSituationActionsApplyThroughSituationQueries() async throws {
        try await dbPool.write { db in
            _ = try TestDatabase.insertSituation(db, title: "One")   // id 1 → done
            _ = try TestDatabase.insertSituation(db, title: "Two")   // id 2 → dismiss
            _ = try TestDatabase.insertSituation(db, title: "Three") // id 3 → snooze
            _ = try TestDatabase.insertSituation(
                db, title: "Four", suggestedResolution: "looks wrapped up"
            ) // id 4 → keep open
        }
        let until = "2026-07-10T12:00:00Z"
        let names = [
            try await enqueue(.situationDone, id: "s1", entityID: "1"),
            try await enqueue(.situationDismiss, id: "s2", entityID: "2"),
            try await enqueue(.situationSnooze, id: "s3", entityID: "3",
                              params: ["snooze_until": .string(until)]),
            try await enqueue(.situationKeepOpen, id: "s4", entityID: "4")
        ]

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 4)
        for name in names {
            let payload = try await statusPayload(recordName: name)
            XCTAssertEqual(payload?.status, .applied)
        }
        // Explicit closure return type: CI's older toolchain fails to infer
        // it through the multiline-string argument and lands on ().
        let rows = try await dbPool.read { db -> [Row] in
            try Row.fetchAll(db, sql: """
                SELECT status, resolved_reason, snooze_until, suggested_resolution
                FROM situations ORDER BY id
                """)
        }
        XCTAssertEqual(rows[0]["status"], "done")
        XCTAssertEqual(rows[0]["resolved_reason"], "user_done")
        XCTAssertEqual(rows[1]["status"], "dismissed")
        XCTAssertEqual(rows[1]["resolved_reason"], "user_dismissed")
        XCTAssertEqual(rows[2]["status"], "snoozed")
        XCTAssertEqual(rows[2]["snooze_until"], until)
        XCTAssertEqual(rows[3]["status"], "open", "keep-open must not close the situation")
        XCTAssertEqual(rows[3]["suggested_resolution"], "")
    }

    // MARK: - Day plan items

    /// Done cascades to the source task — but ONLY for a task-sourced item,
    /// and the decision is made here from the row's own `source_type`, never
    /// from anything the phone sends. Skip never cascades: the block is off
    /// today's plan, the task itself is still open.
    func testDayPlanItemDoneCascadesOnlyForTaskSourcedItems() async throws {
        try await dbPool.write { db in
            _ = try TestDatabase.insertTarget(db, text: "Ship the migration")  // id 1
            let plan = try TestDatabase.insertDayPlan(db)
            _ = try TestDatabase.insertDayPlanItem(
                db, dayPlanID: plan, sourceType: "task", sourceID: "1", title: "Ship the migration"
            ) // id 1 → done, cascades
            _ = try TestDatabase.insertDayPlanItem(
                db, dayPlanID: plan, sourceType: "focus", title: "Deep work"
            ) // id 2 → done, no source task to cascade to
            _ = try TestDatabase.insertDayPlanItem(
                db, dayPlanID: plan, sourceType: "task", sourceID: "1", title: "Second block on the same task"
            ) // id 3 → skipped, must NOT touch the task
        }
        let names = [
            try await enqueue(.dayPlanItemDone, id: "d1", entityID: "1"),
            try await enqueue(.dayPlanItemDone, id: "d2", entityID: "2"),
            try await enqueue(.dayPlanItemSkip, id: "d3", entityID: "3")
        ]

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 3)
        for name in names {
            let payload = try await statusPayload(recordName: name)
            XCTAssertEqual(payload?.status, .applied)
        }
        let statuses = try await dbPool.read { db -> [String] in
            try String.fetchAll(db, sql: "SELECT status FROM day_plan_items ORDER BY id")
        }
        XCTAssertEqual(statuses, ["done", "done", "skipped"])
        let taskStatus = try await dbPool.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = 1")
        }
        XCTAssertEqual(taskStatus, "done", "a task-sourced block completing must close its task")
    }

    /// Skipping a task-sourced block leaves the task alone — the only way to
    /// tell cascade-on-done from cascade-on-any-write.
    func testDayPlanItemSkipDoesNotTouchTheSourceTask() async throws {
        try await dbPool.write { db in
            _ = try TestDatabase.insertTarget(db, text: "Ship the migration")
            let plan = try TestDatabase.insertDayPlan(db)
            _ = try TestDatabase.insertDayPlanItem(
                db, dayPlanID: plan, sourceType: "task", sourceID: "1", title: "Ship the migration"
            )
        }
        try await enqueue(.dayPlanItemSkip, id: "d1", entityID: "1")

        _ = try await processor.processOnce()

        let taskStatus = try await dbPool.read { db -> String? in
            try String.fetchOne(db, sql: "SELECT status FROM targets WHERE id = 1")
        }
        XCTAssertNotEqual(taskStatus, "done")
    }

    func testDayPlanItemActionOnMissingRowFails() async throws {
        let name = try await enqueue(.dayPlanItemDone, id: "d1", entityID: "404")

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 0)
        let payload = try await statusPayload(recordName: name)
        XCTAssertEqual(payload?.status, .failed)
        XCTAssertEqual(payload?.errorMessage, "no row in day_plan_items with id 404")
    }

    /// A situation action against a row that no longer exists fails with the
    /// echoed error instead of silently applying (same contract as inbox).
    func testSituationActionOnMissingRowFails() async throws {
        let name = try await enqueue(.situationDone, id: "s9", entityID: "42")

        let applied = try await processor.processOnce()

        XCTAssertEqual(applied, 0)
        let payload = try await statusPayload(recordName: name)
        XCTAssertEqual(payload?.status, .failed)
        XCTAssertFalse(payload?.errorMessage?.isEmpty ?? true)
    }

    func testHygieneSparesUnprocessedPendingActionAndDeletesAppliedOne() async throws {
        let age: TimeInterval = 8 * 86_400 // 8 days — past the 7-day threshold
        // Use fixedNow as the reference so the injected clock and record ages align.
        let staleModified = fixedNow.addingTimeInterval(-age)

        // A pending action queued by mobile but never yet processed by this desktop.
        let pending = ActionRequestPayload(id: "u1", kind: .targetDone, entityID: "1", createdAt: staleModified)
        let pendingRecord = try CloudRecordFactory.record(for: pending, modifiedAt: staleModified)
        try await transport.save([pendingRecord])

        // An already-applied status echo (our own write-back) — safe to purge by age.
        var applied = ActionRequestPayload(id: "p1", kind: .targetDone, entityID: "1", createdAt: staleModified)
        applied.status = .applied
        let appliedRecord = try CloudRecordFactory.record(for: applied, modifiedAt: staleModified)
        try await transport.save([appliedRecord])

        // Hygiene runs immediately (no prior stamp in the in-memory sidecar).
        try await processor.runHygieneIfDue()

        let batch = try await transport.changes(in: .relay, since: nil)
        let names = Set(batch.changed.map(\.recordName))
        XCTAssertTrue(
            names.contains(pendingRecord.recordName),
            "hygiene must not delete a stale pending action that was never processed"
        )
        XCTAssertFalse(
            names.contains(appliedRecord.recordName),
            "hygiene must delete a stale applied-status echo"
        )
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
