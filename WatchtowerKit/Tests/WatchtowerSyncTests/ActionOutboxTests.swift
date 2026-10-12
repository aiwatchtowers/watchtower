import GRDB
import os
import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// ActionOutbox contract: enqueue writes the relay record BEFORE the pending
/// overlay row (transport throw → no phantom overlay), echoes resolve or fail
/// the overlay, and the silent-pending sweep locally fails rows the desktop
/// never echoed (Plan 3 notes: undecodable actions get no echo, ever).
final class ActionOutboxTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// The paired test phone over one in-memory zone: the outbox seals through `secure`, the replica opens the
    /// overlay with the same key store.
    private struct Phone {
        let inner: any CloudSyncTransport & Sendable
        let keys: InMemoryPhoneKeyStore
        let secure: SecureTransport
        let store: ReplicaStore
    }

    private func makePhone(inner: any CloudSyncTransport & Sendable = InMemoryCloudTransport()) throws -> Phone {
        let keys = try TestE2E.phoneStore()
        return Phone(
            inner: inner,
            keys: keys,
            secure: TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: inner),
            store: try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys)))
    }

    private func makeFixtures(
        clock: OSAllocatedUnfairLock<Date>? = nil
    ) throws -> (transport: SecureTransport, store: ReplicaStore, outbox: ActionOutbox) {
        let phone = try makePhone()
        let frozen = base
        let outbox = ActionOutbox(transport: phone.secure, store: phone.store, deviceID: "D1") {
            clock?.withLock { $0 } ?? frozen
        }
        return (phone.secure, phone.store, outbox)
    }

    /// The relay zone as the phone reads it: its own p2h envelopes opened.
    private func relayRecords(_ transport: SecureTransport) async throws -> [CloudRecord] {
        try await transport.changes(in: .relay, since: nil).changed
    }

    private func decodeAction(_ record: CloudRecord) throws -> ActionRequestPayload {
        try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
    }

    // MARK: - Sealing (mobile E2E: the outbox is encrypted at enqueue)

    func testEnqueueSealsOnceAndTheOverlayReadsTheSealedRow() async throws {
        let phone = try makePhone()
        let outbox = ActionOutbox(transport: phone.secure, store: phone.store, deviceID: "D1") { self.base }

        let id = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")

        let wire = try await phone.inner.changes(in: .relay, since: nil).changed
        XCTAssertEqual(wire.count, 1, "one save")
        let sent = try XCTUnwrap(wire.first)
        XCTAssertEqual(sent.kind, WireKind.envelope)
        XCTAssertEqual(sent.recordName, try phone.secure.wireName(plain: "action-\(id)", zone: .relay))
        XCTAssertEqual(try Envelope.parse(sent.payload).header.envelopeClass, .relayToHub)
        let row = try await phone.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT wire_name, payload FROM pending_actions WHERE action_id = ?", arguments: [id])
        }
        let stored = try XCTUnwrap(row)
        XCTAssertEqual(stored["wire_name"] as String?, sent.recordName)
        XCTAssertEqual(stored["payload"] as Data, sent.payload, "the overlay keeps the envelope it sent: sealed once")
        XCTAssertNil((stored["payload"] as Data).range(of: Data(id.utf8)), "no plaintext action at rest")

        let pending = try XCTUnwrap(phone.store.pendingActions().first)
        XCTAssertEqual(pending.id, id)
        XCTAssertEqual(pending.action.kind, .targetDone)
        XCTAssertEqual(pending.action.entityID, "42")
        XCTAssertEqual(pending.action.createdAt, base)
    }

    /// Locked is its own state: the overlay read throws instead of reading as "no pending actions".
    func testTheOverlayReadThrowsLockedWhileTheKeychainIsLocked() async throws {
        let phone = try makePhone()
        let outbox = ActionOutbox(transport: phone.secure, store: phone.store, deviceID: "D1")
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")

        phone.keys.isLocked = true
        XCTAssertThrowsError(try phone.store.pendingActions()) { XCTAssertEqual($0 as? KeyStoreError, .locked) }

        phone.keys.isLocked = false
        XCTAssertEqual(try phone.store.pendingActions().count, 1)
    }

    /// A locked keychain cannot seal: enqueue throws and leaves no overlay row and no record.
    func testEnqueueWhileLockedSendsNothing() async throws {
        let phone = try makePhone()
        let outbox = ActionOutbox(transport: phone.secure, store: phone.store, deviceID: "D1")
        phone.keys.isLocked = true

        do {
            _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
            XCTFail("sealing needs the unlocked keychain")
        } catch KeyStoreError.locked {
            // expected
        }

        let wire = try await phone.inner.changes(in: .relay, since: nil).changed
        XCTAssertTrue(wire.isEmpty)
        phone.keys.isLocked = false
        XCTAssertTrue(try phone.store.pendingActions().isEmpty)
    }

    /// A row written before E2E holds a plaintext payload for a hub the hard cut removed: it is dropped when the
    /// overlay gains `wire_name`, so no plaintext action stays at rest.
    func testAPlaintextOverlayRowFromBeforeE2EIsDroppedOnOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("replica.sqlite").path
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: """
                CREATE TABLE pending_actions (
                    action_id TEXT PRIMARY KEY, kind TEXT NOT NULL, entity_record_name TEXT, payload BLOB NOT NULL,
                    created_at REAL NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','failed')),
                    error_message TEXT, reason TEXT, result BLOB, echo_status TEXT);
                INSERT INTO pending_actions (action_id, kind, payload, created_at, state)
                    VALUES ('A1', 'probe', '{"id":"A1"}', 1700000000, 'pending');
                """)
        }

        let store = try ReplicaStore(path: path, opener: TestE2E.opener())

        XCTAssertTrue(try store.pendingActions().isEmpty)
        let count = try store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_actions") }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Enqueue

    func testEnqueueSavesRelayRecordAndInsertsPendingRow() async throws {
        let (transport, store, outbox) = try makeFixtures()

        let id = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")

        let records = try await relayRecords(transport)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, RelayRecordKind.action.rawValue)
        XCTAssertEqual(record.recordName, "action-\(id)")

        let wire = try decodeAction(record)
        XCTAssertEqual(wire.id, id)
        XCTAssertEqual(wire.kind, .targetDone)
        XCTAssertEqual(wire.entityID, "42")
        XCTAssertEqual(wire.status, .pending)
        XCTAssertEqual(wire.createdAt, base)

        let pending = try store.pendingActions()
        XCTAssertEqual(pending.count, 1)
        let row = try XCTUnwrap(pending.first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.entityRecordName, "target-42")
        XCTAssertEqual(row.createdAt, base)
        XCTAssertNil(row.errorMessage)
        XCTAssertEqual(row.action, wire)
    }

    func testEnqueueDerivesEntityIDAfterFirstHyphen() async throws {
        // SliceKind rawValues use underscores, never hyphens, so the FIRST
        // hyphen splits kind from id — even for underscored kinds.
        let (transport, _, outbox) = try makeFixtures()

        _ = try await outbox.enqueue(kind: .inboxResolve, entityRecordName: "inbox_item-7")

        let records = try await relayRecords(transport)
        let wire = try decodeAction(try XCTUnwrap(records.first))
        XCTAssertEqual(wire.entityID, "7")
    }

    func testEnqueueTaskCreateHasNilEntityID() async throws {
        let (transport, store, outbox) = try makeFixtures()

        _ = try await outbox.enqueue(
            kind: .taskCreate,
            entityRecordName: nil,
            params: ["text": .string("Buy milk")]
        )

        let records = try await relayRecords(transport)
        let wire = try decodeAction(try XCTUnwrap(records.first))
        XCTAssertNil(wire.entityID)
        XCTAssertEqual(wire.params["text"], .string("Buy milk"))
        XCTAssertNil(try XCTUnwrap(store.pendingActions().first).entityRecordName)
    }

    private struct SaveError: Error {}

    private actor ThrowingSaveTransport: CloudSyncTransport {
        func save(_ records: [CloudRecord]) async throws { throw SaveError() }
        func delete(recordNames: [String], in zone: CloudZoneID) async throws {}
        func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
            CloudChangeBatch(changed: [], deletedRecordNames: [], newToken: CloudChangeToken(value: 0))
        }
    }

    // MARK: - Device id (spec §5.2 rule 4: the hub gates on it)

    func testEnqueueStampsTheLinkedDeviceID() async throws {
        let (transport, store, outbox) = try makeFixtures()

        _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil, params: ["nonce": .string("n-1")])

        let records = try await relayRecords(transport)
        let wire = try decodeAction(try XCTUnwrap(records.first))
        XCTAssertEqual(wire.deviceID, "D1")
        XCTAssertEqual(try XCTUnwrap(store.pendingActions().first).action.deviceID, "D1")
    }

    func testUnlinkedOutboxRefusesToEnqueue() async throws {
        let phone = try makePhone()
        let (transport, store) = (phone.secure, phone.store)
        let outbox = ActionOutbox(transport: transport, store: store)

        do {
            _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil)
            XCTFail("an outbox with no device id must refuse to enqueue")
        } catch ActionOutboxError.notLinked {
            // expected
        }

        let records = try await relayRecords(transport)
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    /// An empty device id is no link: the hub's device gate would reject
    /// every action stamped "" (final-review A-T3).
    func testEmptyDeviceIDCountsAsUnlinked() async throws {
        let phone = try makePhone()
        let (transport, store) = (phone.secure, phone.store)
        let viaInit = ActionOutbox(transport: transport, store: store, deviceID: "")
        let viaSetter = ActionOutbox(transport: transport, store: store, deviceID: "D1")
        await viaSetter.setDeviceID("  ")

        for outbox in [viaInit, viaSetter] {
            do {
                _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil)
                XCTFail("an empty device id must refuse to enqueue")
            } catch ActionOutboxError.notLinked {
                // expected
            }
        }
        let records = try await relayRecords(transport)
        XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    func testSetDeviceIDLinksAndUnlinksTheOutbox() async throws {
        let phone = try makePhone()
        let (transport, store) = (phone.secure, phone.store)
        let outbox = ActionOutbox(transport: transport, store: store)

        await outbox.setDeviceID("D2")
        _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil)
        let records = try await relayRecords(transport)
        XCTAssertEqual(try decodeAction(try XCTUnwrap(records.first)).deviceID, "D2")

        await outbox.setDeviceID(nil)
        do {
            _ = try await outbox.enqueue(kind: .probe, entityRecordName: nil)
            XCTFail("unlinking must stop enqueues again")
        } catch ActionOutboxError.notLinked {
            // expected
        }
        XCTAssertEqual(try store.pendingActions().count, 1)
    }

    func testEnqueueTransportThrowLeavesNoPendingRow() async throws {
        let phone = try makePhone(inner: ThrowingSaveTransport())
        let store = phone.store
        let outbox = ActionOutbox(transport: phone.secure, store: store, deviceID: "D1")

        do {
            _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
            XCTFail("expected the transport error to propagate")
        } catch is SaveError {
            // expected
        }

        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    // MARK: - Echoes

    func testAppliedEchoRemovesPendingRow() async throws {
        let (_, store, outbox) = try makeFixtures()
        _ = try await outbox.enqueue(kind: .inboxDismiss, entityRecordName: "inbox_item-3")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .applied
        try await outbox.applyEcho(echo)

        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    /// The overlay row goes on `applied`, so the observer is how the phone
    /// learns an applied echo's result (an ask answer's `delivery`): once
    /// per row it removes, never for an unknown id or another status.
    func testAppliedObserverSeesTheAppliedEchoOfAKnownRowOnce() async throws {
        let (_, store, outbox) = try makeFixtures()
        let seen = OSAllocatedUnfairLock<[ActionRequestPayload]>(initialState: [])
        await outbox.setAppliedObserver { action in seen.withLock { $0.append(action) } }
        _ = try await outbox.enqueue(kind: .askAnswer, entityRecordName: "owner_ask-109")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .received
        try await outbox.applyEcho(echo)
        XCTAssertTrue(seen.withLock { $0 }.isEmpty, "received is still in flight")

        echo.status = .applied
        echo.result = ["delivery": .string("submitted")]
        try await outbox.applyEcho(echo)
        try await outbox.applyEcho(echo)

        var ghost = ActionRequestPayload(id: "ghost", kind: .askAnswer, entityID: "1", createdAt: base)
        ghost.status = .applied
        try await outbox.applyEcho(ghost)

        let applied = seen.withLock { $0 }
        XCTAssertEqual(applied.map(\.id), [echo.id], "a redelivered or unknown echo fires nothing")
        XCTAssertEqual(applied.first?.result, ["delivery": .string("submitted")])
    }

    /// A start sheet's "Mac picked it up" stage reads the last non-terminal
    /// echo: `received` and `held` mark the still-pending row, and a later
    /// `applied` still removes it and tells the observer its result.
    func testReceivedEchoMarksThePendingRowAndAppliedStillRemovesIt() async throws {
        let (_, store, outbox) = try makeFixtures()
        let seen = OSAllocatedUnfairLock<[ActionRequestPayload]>(initialState: [])
        await outbox.setAppliedObserver { action in seen.withLock { $0.append(action) } }
        _ = try await outbox.enqueue(kind: .sessionStart, entityRecordName: "workbench_target-415")
        XCTAssertNil(try XCTUnwrap(store.pendingActions().first).echoStatus, "no echo yet")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .received
        try await outbox.applyEcho(echo)
        var row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.echoStatus, .received)

        echo.status = .held
        try await outbox.applyEcho(echo)
        row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.state, .pending)
        XCTAssertEqual(row.echoStatus, .held, "the last non-terminal echo wins")

        echo.status = .applied
        echo.result = ["session_id": .integer(42), "stage": .string("starting")]
        try await outbox.applyEcho(echo)
        XCTAssertTrue(try store.pendingActions().isEmpty)
        XCTAssertEqual(seen.withLock { $0 }.map(\.result), [["session_id": .integer(42), "stage": .string("starting")]])
    }

    /// A `received` redelivered after a refusal never turns the failed row
    /// back into an in-flight one; an unknown id stays a no-op.
    func testReceivedEchoAfterAFailureLeavesTheFailedRow() async throws {
        let (_, store, outbox) = try makeFixtures()
        _ = try await outbox.enqueue(kind: .sessionStart, entityRecordName: "workbench_target-415")
        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .failed
        echo.reason = .claudeNotFound
        echo.errorMessage = "Claude Code was not found"
        try await outbox.applyEcho(echo)

        echo.status = .received
        try await outbox.applyEcho(echo)
        var ghost = ActionRequestPayload(id: "ghost", kind: .sessionStart, entityID: "1", createdAt: base)
        ghost.status = .received
        try await outbox.applyEcho(ghost)

        let rows = try store.pendingActions()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.state, .failed)
        XCTAssertEqual(rows.first?.reason, .claudeNotFound)
        XCTAssertNil(rows.first?.echoStatus)
    }

    func testFailedEchoMarksRowFailedWithMessage() async throws {
        let (_, store, outbox) = try makeFixtures()
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-9")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .failed
        echo.errorMessage = "targets row 9 not found"
        try await outbox.applyEcho(echo)

        let row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, "targets row 9 not found")
        XCTAssertNil(row.reason)
        XCTAssertNil(row.result)
    }

    /// The overlay keeps a failed echo's reason and result (a conflict's
    /// `current`), so the phone can offer "apply anyway".
    func testFailedEchoKeepsReasonAndResult() async throws {
        let (_, store, outbox) = try makeFixtures()
        _ = try await outbox.enqueue(kind: .boardTargetStatus, entityRecordName: "workbench_target-415")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .failed
        echo.reason = .conflict
        echo.result = ["current": .string("blocked"), "nested": .object(["n": .integer(3)])]
        echo.errorMessage = "Changed on the Mac to blocked"
        try await outbox.applyEcho(echo)

        let row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.reason, .conflict)
        XCTAssertEqual(row.result, ["current": .string("blocked"), "nested": .object(["n": .integer(3)])])
        XCTAssertEqual(row.errorMessage, "Changed on the Mac to blocked")
    }

    /// An expired echo keeps its reason too; one without a result stores none.
    func testExpiredEchoKeepsReasonWithoutResult() async throws {
        let (_, store, outbox) = try makeFixtures()
        _ = try await outbox.enqueue(kind: .boardCommentAdd, entityRecordName: "workbench_target-415")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .expired
        echo.reason = .expired
        try await outbox.applyEcho(echo)

        let row = try XCTUnwrap(store.pendingActions().first)
        XCTAssertEqual(row.reason, .expired)
        XCTAssertNil(row.result)
        XCTAssertEqual(row.errorMessage, "Failed on the desktop (no message)")
    }

    func testEchoForUnknownActionIDIsNoOp() async throws {
        // Redelivery after a sweep removed the row, or the phantom case
        // (transport save succeeded, pending insert threw): both must be inert.
        let (_, store, outbox) = try makeFixtures()

        var echo = ActionRequestPayload(id: "ghost", kind: .targetDone, entityID: "1", createdAt: base)
        echo.status = .applied
        try await outbox.applyEcho(echo)
        echo.status = .failed
        echo.errorMessage = "boom"
        try await outbox.applyEcho(echo)

        XCTAssertTrue(try store.pendingActions().isEmpty)
    }

    func testPendingStatusEchoIsNoOp() async throws {
        // RelayFeed skips own-enqueue echoes (status pending), but applyEcho
        // itself must also treat them as inert — belt and braces.
        let (_, store, outbox) = try makeFixtures()
        _ = try await outbox.enqueue(kind: .trackRead, entityRecordName: "track-5")

        let echo = try XCTUnwrap(store.pendingActions().first).action
        try await outbox.applyEcho(echo)

        XCTAssertEqual(try XCTUnwrap(store.pendingActions().first).state, .pending)
    }

    // MARK: - Silent-pending sweep

    func testSweepFailsOnlyRowsOlderThanTwentyFourHours() async throws {
        let clock = OSAllocatedUnfairLock(initialState: base.addingTimeInterval(-25 * 3600))
        let (_, store, outbox) = try makeFixtures(clock: clock)

        let old = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        clock.withLock { $0 = base.addingTimeInterval(-23 * 3600) }
        let recent = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-2")
        clock.withLock { $0 = base }

        let swept = try await outbox.sweepSilentPending()

        XCTAssertEqual(swept, [old])
        let rows = try store.pendingActions()
        let oldRow = try XCTUnwrap(rows.first { $0.id == old })
        XCTAssertEqual(oldRow.state, .failed)
        XCTAssertEqual(oldRow.errorMessage, ActionOutbox.silentPendingMessage)
        let recentRow = try XCTUnwrap(rows.first { $0.id == recent })
        XCTAssertEqual(recentRow.state, .pending)
        XCTAssertNil(recentRow.errorMessage)
    }

    func testSweepSkipsAlreadyFailedRows() async throws {
        let clock = OSAllocatedUnfairLock(initialState: base.addingTimeInterval(-25 * 3600))
        let (_, store, outbox) = try makeFixtures(clock: clock)
        _ = try await outbox.enqueue(kind: .inboxSnooze, entityRecordName: "inbox_item-4")

        var echo = try XCTUnwrap(store.pendingActions().first).action
        echo.status = .failed
        echo.errorMessage = "desktop said no"
        try await outbox.applyEcho(echo)
        clock.withLock { $0 = base }

        let swept = try await outbox.sweepSilentPending()

        XCTAssertTrue(swept.isEmpty)
        // The desktop's real error message must survive the sweep.
        XCTAssertEqual(try XCTUnwrap(store.pendingActions().first).errorMessage, "desktop said no")
    }

    // MARK: - Snooze wire fixture

    func testSnoozeParamsProduceFrozenISO8601WireForm() async throws {
        // Producer-side pin: the desktop parser accepts plain + fractional
        // ISO8601 (Plan 2/3); mobile always sends the plain UTC form.
        let (transport, _, outbox) = try makeFixtures()

        _ = try await outbox.enqueue(
            kind: .targetSnooze,
            entityRecordName: "target-9",
            params: ActionOutbox.snoozeParams(until: Date(timeIntervalSince1970: 1_700_000_000))
        )

        let records = try await relayRecords(transport)
        let record = try XCTUnwrap(records.first)
        let json = try XCTUnwrap(String(bytes: record.payload, encoding: .utf8))
        XCTAssertTrue(
            json.contains(#""params":{"snooze_until":"2023-11-14T22:13:20Z"}"#),
            "unexpected wire form: \(json)"
        )
    }

    // MARK: - Overlay reads

    func testPendingActionsForEntityFiltersByRecordName() async throws {
        let (_, store, outbox) = try makeFixtures()
        let matching = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-2")

        let filtered = try store.pendingActions(forEntity: "target-1")
        XCTAssertEqual(filtered.map(\.id), [matching])
        XCTAssertEqual(try store.pendingActions().count, 2)
    }

    @MainActor
    func testValueObservationOnPendingActionsFires() async throws {
        // The overlay is driven by ValueObservation in the app's view models;
        // the tracking closure uses the from-db overload (pool-reentrancy rule).
        let (_, store, outbox) = try makeFixtures()

        let observed = expectation(description: "observation sees the pending row")
        let observation = ValueObservation.tracking { db in
            try store.pendingActions(from: db)
        }
        let cancellable = observation.start(
            in: store.reader,
            onError: { XCTFail("observation error: \($0)") },
            onChange: { rows in
                if rows.count == 1 { observed.fulfill() }
            }
        )
        defer { cancellable.cancel() }

        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-1")
        await fulfillment(of: [observed], timeout: 5)
    }
}
