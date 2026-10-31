import GRDB
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The ordered outbox in the replica (relay client Phase 1, Task 5): the gapless `action_seq` counter, the
/// delivery states of an ordered row, the Not delivered list, the one Dismiss, and the control queue.
final class ReplicaOutboxTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private struct Phone {
        let secure: SecureTransport
        let store: ReplicaStore
    }

    private func makePhone(path: String? = nil) throws -> Phone {
        let keys = try TestE2E.phoneStore()
        let opener = try TestE2E.opener(store: keys)
        return Phone(
            secure: TestE2E.phoneTransport(try TestE2E.phone(store: keys)),
            store: try path.map { try ReplicaStore(path: $0, opener: opener) } ?? ReplicaStore.inMemory(opener: opener))
    }

    private func action(_ id: String, kind: ActionKind = .targetDone) -> ActionRequestPayload {
        ActionRequestPayload(id: id, kind: kind, entityID: "42", createdAt: base, deviceID: "D1")
    }

    private func sealed(_ action: ActionRequestPayload, _ phone: Phone) async throws -> CloudRecord {
        try await phone.secure.seal(try CloudRecordFactory.record(for: action, modifiedAt: action.createdAt))
    }

    /// Inserts ordered rows `a1…aN` at seqs 1…N under epoch 1.
    @discardableResult
    private func insertOrdered(_ count: Int, _ phone: Phone, epoch: UInt32 = 1) async throws -> [String] {
        var ids: [String] = []
        for index in 1...count {
            let request = action("a\(index)")
            let record = try await sealed(request, phone)
            let seq = try phone.store.nextActionSeq()
            XCTAssertTrue(try phone.store.insertOrderedAction(
                request, entityRecordName: "target-42", sealed: record, epoch: epoch, seq: seq))
            ids.append(request.id)
        }
        return ids
    }

    private func deliveries(_ store: ReplicaStore) throws -> [String: Delivery] {
        let rows = try store.outboxRows([.queued, .sent, .settled, .undelivered])
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.actionID, $0.delivery) })
    }

    private func tempPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("replica.sqlite").path
    }

    // MARK: - The counter

    func testTheCounterAdvancesOnlyWithAnInsertedRow() async throws {
        let phone = try makePhone()
        XCTAssertEqual(try phone.store.nextActionSeq(), 1)
        let first = action("a1")
        let firstRecord = try await sealed(first, phone)
        XCTAssertTrue(try phone.store.insertOrderedAction(
            first, entityRecordName: nil, sealed: firstRecord, epoch: 1, seq: 1))
        XCTAssertEqual(try phone.store.nextActionSeq(), 2)

        // A writer that read the counter before the insert above lost the race: nothing is written.
        let late = action("a2")
        let lateRecord = try await sealed(late, phone)
        XCTAssertFalse(try phone.store.insertOrderedAction(
            late, entityRecordName: nil, sealed: lateRecord, epoch: 1, seq: 1))
        XCTAssertEqual(try phone.store.nextActionSeq(), 2)
        XCTAssertEqual(try phone.store.outboxRows([.queued]).map(\.actionID), ["a1"])

        XCTAssertTrue(try phone.store.insertOrderedAction(
            late, entityRecordName: nil, sealed: lateRecord, epoch: 1, seq: 2))
        XCTAssertEqual(try phone.store.outboxRows([.queued]).map(\.actionSeq), [1, 2])
        XCTAssertEqual(try phone.store.nextActionSeq(), 3)
    }

    func testAnUnreadableCounterThrows() async throws {
        let phone = try makePhone()
        try await phone.store.writer.write { db in
            try db.execute(sql: "INSERT INTO replica_meta (key, value) VALUES ('action_seq_next', 'x')")
        }
        XCTAssertThrowsError(try phone.store.nextActionSeq())
    }

    func testARowKeepsItsEpoch() async throws {
        let phone = try makePhone()
        let request = action("a1")
        let record = try await sealed(request, phone)
        XCTAssertTrue(try phone.store.insertOrderedAction(
            request, entityRecordName: "target-42", sealed: record, epoch: 3, seq: 1))

        let row = try XCTUnwrap(try phone.store.outboxRows([.queued]).first)
        XCTAssertEqual(row.epoch, 3)
        XCTAssertEqual(row.actionSeq, 1)
        XCTAssertEqual(row.wireName, record.recordName)
        XCTAssertEqual(row.envelope, record.payload)
        XCTAssertNil(row.recordSeq)
        XCTAssertNil(row.sentAt)
        let overlay = try XCTUnwrap(try phone.store.pendingActions().first)
        XCTAssertEqual(overlay.actionSeq, 1)
        XCTAssertEqual(overlay.epoch, 3)
        XCTAssertEqual(overlay.delivery, .queued)
        XCTAssertEqual(overlay.state, .pending)
        XCTAssertNil(overlay.undeliveredReason)
    }

    // MARK: - Delivery states

    func testRequeueReturnsTheFirstRowStillHeld() async throws {
        let phone = try makePhone()
        try await insertOrdered(4, phone)
        try phone.store.markSent(actionID: "a1", recordSeq: 11, at: base)
        try phone.store.markSent(actionID: "a2", recordSeq: 12, at: base)
        try phone.store.markSent(actionID: "a3", recordSeq: 13, at: base)
        try phone.store.setDelivery(.settled, actionIDs: ["a2"])
        try phone.store.markUndelivered(actionIDs: ["a4"], reason: .refused, message: "Not delivered to your Mac.")

        XCTAssertEqual(try phone.store.requeue(fromSeq: 1), 1)
        XCTAssertEqual(try deliveries(phone.store), ["a1": .queued, "a2": .settled, "a3": .queued, "a4": .undelivered])
        // The requeued row keeps the version of its last write.
        XCTAssertEqual(try phone.store.outboxRows([.queued]).map(\.recordSeq), [11, 13])
        XCTAssertEqual(try phone.store.outboxRows(fromSeq: 2, below: 4).map(\.actionID), ["a2", "a3"])

        XCTAssertNil(try phone.store.requeue(fromSeq: 4))
    }

    func testMarkSentOnlyMovesAQueuedRow() async throws {
        let phone = try makePhone()
        try await insertOrdered(1, phone)
        try phone.store.markSent(actionID: "a1", recordSeq: 5, at: base)
        XCTAssertEqual(try phone.store.outboxRows([.sent]).first?.sentAt, base)

        // The write landed, a `resend_from` put the row back meanwhile: the late `markSent` of the first write
        // must not move it.
        XCTAssertEqual(try phone.store.requeue(fromSeq: 1), 1)
        try phone.store.markSent(actionID: "a1", recordSeq: 5, at: base)
        // markSent leaves a non-queued row alone too.
        try phone.store.setDelivery(.settled, actionIDs: ["a1"])
        try phone.store.markSent(actionID: "a1", recordSeq: 9, at: base.addingTimeInterval(1))
        let row = try XCTUnwrap(try phone.store.outboxRows([.settled]).first)
        XCTAssertEqual(row.recordSeq, 5)
        XCTAssertEqual(row.sentAt, base)
    }

    func testMarkSentAfterARequeueMovesTheRowAgain() async throws {
        let phone = try makePhone()
        try await insertOrdered(1, phone)
        try phone.store.markSent(actionID: "a1", recordSeq: 5, at: base)
        _ = try phone.store.requeue(fromSeq: 1)
        XCTAssertEqual(try deliveries(phone.store), ["a1": .queued])
        try phone.store.markSent(actionID: "a1", recordSeq: 6, at: base.addingTimeInterval(5))
        let row = try XCTUnwrap(try phone.store.outboxRows([.sent]).first)
        XCTAssertEqual(row.recordSeq, 6)
        XCTAssertEqual(row.sentAt, base.addingTimeInterval(5))
    }

    func testUndeliveredRowsReadAsFailed() async throws {
        let phone = try makePhone()
        try await insertOrdered(2, phone)
        try phone.store.markSent(actionID: "a2", recordSeq: 1, at: base)
        try phone.store.markUndelivered(actionIDs: ["a1"], reason: .refused, message: "Not delivered to your Mac.")
        try phone.store.markUndelivered(
            actionIDs: ["a2"], reason: .noAnswer, message: "No answer from your Mac for 24 hours.")
        // A row already listed keeps its first reason and message.
        try phone.store.markUndelivered(actionIDs: ["a1"], reason: .noAnswer, message: "later")

        let overlay = try phone.store.pendingActions()
        XCTAssertEqual(overlay.map(\.state), [.failed, .failed])
        XCTAssertEqual(overlay.map(\.delivery), [.undelivered, .undelivered])
        XCTAssertEqual(overlay.map(\.undeliveredReason), [.refused, .noAnswer])
        XCTAssertEqual(
            overlay.map(\.errorMessage), ["Not delivered to your Mac.", "No answer from your Mac for 24 hours."])

        let listed = try await phone.store.reader.read { db in try phone.store.undeliveredActions(from: db) }
        XCTAssertEqual(listed.map(\.id), ["a1", "a2"])
        XCTAssertEqual(listed.first?.action.kind, .targetDone)
        let counts = try await phone.store.reader.read { db in try phone.store.outboxCounts(from: db) }
        XCTAssertEqual(counts.queued, 0)
        XCTAssertEqual(counts.undelivered, 2)
    }

    func testOutboxCountsCountOnlyQueuedAndUndelivered() async throws {
        let phone = try makePhone()
        try await insertOrdered(4, phone)
        try phone.store.markSent(actionID: "a2", recordSeq: 1, at: base)
        try phone.store.markUndelivered(actionIDs: ["a3"], reason: .refused, message: "x")
        let counts = try await phone.store.reader.read { db in try phone.store.outboxCounts(from: db) }
        XCTAssertEqual(counts.queued, 2)
        XCTAssertEqual(counts.undelivered, 1)
    }

    func testDismissAllRemovesOnlyUndelivered() async throws {
        let phone = try makePhone()
        try await insertOrdered(3, phone)
        let legacy = action("legacy")
        try phone.store.insertPendingAction(legacy, entityRecordName: nil, sealed: try await sealed(legacy, phone))
        _ = try phone.store.sweepPendingActions(before: base.addingTimeInterval(1), errorMessage: "swept")
        try phone.store.markUndelivered(actionIDs: ["a1", "a3"], reason: .refused, message: "x")

        XCTAssertEqual(try phone.store.dismissAllUndelivered(), 2)
        XCTAssertEqual(try phone.store.pendingActions().map(\.id).sorted(), ["a2", "legacy"])
        XCTAssertEqual(try phone.store.dismissAllUndelivered(), 0)
    }

    func testDismissRefusesARowOnItsWay() async throws {
        let phone = try makePhone()
        try await insertOrdered(3, phone)
        try phone.store.markSent(actionID: "a2", recordSeq: 1, at: base)
        try phone.store.markSent(actionID: "a3", recordSeq: 2, at: base)
        try phone.store.setDelivery(.settled, actionIDs: ["a3"])

        XCTAssertFalse(try phone.store.dismissAction(id: "a1"), "queued")
        XCTAssertFalse(try phone.store.dismissAction(id: "a2"), "sent")
        XCTAssertTrue(try phone.store.dismissAction(id: "a3"), "settled")
        XCTAssertFalse(try phone.store.dismissAction(id: "missing"))
        try phone.store.markUndelivered(actionIDs: ["a1"], reason: .refused, message: "x")
        XCTAssertTrue(try phone.store.dismissAction(id: "a1"), "undelivered")

        // A legacy row (no delivery) is dismissed as today.
        let legacy = action("legacy")
        try phone.store.insertPendingAction(legacy, entityRecordName: nil, sealed: try await sealed(legacy, phone))
        XCTAssertTrue(try phone.store.dismissAction(id: "legacy"))
        XCTAssertEqual(try phone.store.pendingActions().map(\.id), ["a2"])
    }

    func testTheLegacySweepSkipsOrderedRows() async throws {
        let phone = try makePhone()
        try await insertOrdered(1, phone)
        let legacy = action("legacy")
        try phone.store.insertPendingAction(legacy, entityRecordName: nil, sealed: try await sealed(legacy, phone))

        let swept = try phone.store.sweepPendingActions(before: base.addingTimeInterval(86_400), errorMessage: "swept")
        XCTAssertEqual(swept, ["legacy"])
        let overlay = Dictionary(uniqueKeysWithValues: try phone.store.pendingActions().map { ($0.id, $0) })
        XCTAssertEqual(overlay["a1"]?.state, .pending)
        XCTAssertEqual(overlay["legacy"]?.state, .failed)
        XCTAssertNil(overlay["legacy"]?.delivery)
        XCTAssertNil(overlay["legacy"]?.actionSeq)
    }

    // MARK: - Controls

    func testControlsQueueInOrderAndHandledIdsAreRememberedOnce() async throws {
        let phone = try makePhone()
        let controls = (1...3).map { index in
            QueuedControl(
                id: "C\(index)", kind: .skipTo, wireName: "w\(index)", envelope: Data([UInt8(index)]),
                queuedAt: base.addingTimeInterval(Double(index)))
        }
        // Inserted out of their id order: the queue keeps insertion order.
        for control in [controls[1], controls[0], controls[2]] { try phone.store.enqueueControl(control) }
        XCTAssertEqual(try phone.store.queuedControls(), [controls[1], controls[0], controls[2]])
        try phone.store.controlWritten(id: "C1")
        XCTAssertEqual(try phone.store.queuedControls().map(\.id), ["C2", "C3"])

        XCTAssertTrue(try phone.store.markControlHandled(id: "H1", at: base))
        XCTAssertFalse(try phone.store.markControlHandled(id: "H1", at: base.addingTimeInterval(60)))
        // Past 15 days the id is pruned (sim "Bounded state").
        XCTAssertTrue(try phone.store.markControlHandled(id: "H1", at: base.addingTimeInterval(16 * 86_400)))
        try phone.store.pruneHandledControls(before: base.addingTimeInterval(17 * 86_400))
        XCTAssertTrue(try phone.store.markControlHandled(id: "H1", at: base.addingTimeInterval(17 * 86_400)))
    }

    // MARK: - Upgrade and format wipe

    func testAReplicaFromBeforeTheOutboxOpensWithItsRows() async throws {
        let path = try tempPath()
        let seed = try makePhone()
        let request = action("old")
        let record = try await sealed(request, seed)
        try await DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE replica_meta (key TEXT PRIMARY KEY, value TEXT);
                INSERT INTO replica_meta VALUES ('replica_format', '2');
                CREATE TABLE pending_actions (
                    action_id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_record_name TEXT,
                    payload BLOB NOT NULL, created_at REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('pending','failed')), error_message TEXT,
                    reason TEXT, result BLOB, echo_status TEXT, wire_name TEXT
                );
                """)
            try db.execute(
                sql: """
                    INSERT INTO pending_actions (action_id, kind, entity_record_name, payload, wire_name, created_at, state)
                    VALUES ('old', 'target_done', 'target-42', ?, ?, 1700000000, 'pending')
                    """,
                arguments: [record.payload, record.recordName])
        }

        let phone = try makePhone(path: path)
        let overlay = try phone.store.pendingActions()
        XCTAssertEqual(overlay.map(\.id), ["old"])
        XCTAssertNil(overlay.first?.actionSeq)
        XCTAssertNil(overlay.first?.epoch)
        XCTAssertNil(overlay.first?.delivery)
        XCTAssertNil(overlay.first?.undeliveredReason)
        XCTAssertEqual(try phone.store.outboxRows([.queued, .sent, .settled, .undelivered]), [])
        // The new columns, index and tables are there.
        let columns = try await phone.store.reader.read { db in try db.columns(in: "pending_actions").map(\.name) }
        XCTAssertTrue(
            Set(columns).isSuperset(of: ["action_seq", "epoch", "record_seq", "sent_at", "delivery", "undelivered_reason"]))
        try await insertOrdered(1, phone)
        XCTAssertTrue(try phone.store.dismissAction(id: "old"))
        XCTAssertEqual(try phone.store.queuedControls(), [])
    }

    func testAnActionSeqIsUniqueAcrossRows() async throws {
        let phone = try makePhone()
        try await insertOrdered(1, phone)
        do {
            try await phone.store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO pending_actions (action_id, kind, payload, created_at, state, action_seq, delivery)
                    VALUES ('dup', 'target_done', X'00', 0, 'pending', 1, 'queued')
                    """)
            }
            XCTFail("a second row with action_seq 1 was accepted")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_CONSTRAINT)
        }
    }

    func testSetDeliveryRefusesUndeliveredAndALeavingRowIsPendingAgain() async throws {
        let phone = try makePhone()
        try await insertOrdered(2, phone)
        XCTAssertThrowsError(try phone.store.setDelivery(.undelivered, actionIDs: ["a1"]))
        XCTAssertEqual(try deliveries(phone.store), ["a1": .queued, "a2": .queued])

        try phone.store.markUndelivered(actionIDs: ["a1"], reason: .refused, message: "Not delivered to your Mac.")
        try phone.store.setDelivery(.sent, actionIDs: ["a1"])
        let row = try XCTUnwrap(try phone.store.pendingActions().first { $0.id == "a1" })
        XCTAssertEqual(row.delivery, .sent)
        XCTAssertEqual(row.state, .pending)
        XCTAssertNil(row.undeliveredReason)
        XCTAssertNil(row.errorMessage)
    }

    /// An ordered row with no wire name (never written so by this module) cannot be sent.
    func testAnUnreadableOrderedRowIsSkippedAndNotedOnce() async throws {
        let phone = try makePhone()
        try await insertOrdered(1, phone)
        try await phone.store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO pending_actions (action_id, kind, payload, created_at, state, action_seq, delivery)
                VALUES ('broken', 'target_done', X'00', 0, 'pending', 2, 'queued')
                """)
        }
        XCTAssertEqual(try phone.store.outboxRows(fromSeq: 1, below: 3).map(\.actionID), ["a1"])
        XCTAssertEqual(try phone.store.outboxRows(fromSeq: 1, below: 3).map(\.actionID), ["a1"])
        XCTAssertEqual(phone.store.corruptPending.withLock { $0 }, ["broken"])
    }

    func testTheOrderedFlagAndCounterSurviveTheFormatWipe() async throws {
        let path = try tempPath()
        do {
            let phone = try makePhone(path: path)
            XCTAssertFalse(try phone.store.orderedActionsEnabled())
            try phone.store.enableOrderedActions()
            try phone.store.enableOrderedActions()
            XCTAssertTrue(try phone.store.orderedActionsEnabled())
            try await insertOrdered(2, phone)
            try phone.store.enqueueControl(QueuedControl(
                id: "C1", kind: .skipTo, wireName: "w", envelope: Data([1]), queuedAt: base))
            XCTAssertTrue(try phone.store.markControlHandled(id: "H1", at: base))
        }
        try await DatabaseQueue(path: path).write { db in
            try db.execute(sql: "UPDATE replica_meta SET value = '1' WHERE key = 'replica_format'")
        }

        let phone = try makePhone(path: path)
        XCTAssertTrue(try phone.store.orderedActionsEnabled())
        XCTAssertEqual(try phone.store.nextActionSeq(), 3)
        XCTAssertEqual(try phone.store.outboxRows([.queued]).map(\.actionSeq), [1, 2])
        XCTAssertEqual(try phone.store.queuedControls().map(\.id), ["C1"])
        XCTAssertFalse(try phone.store.markControlHandled(id: "H1", at: base))
    }
}
