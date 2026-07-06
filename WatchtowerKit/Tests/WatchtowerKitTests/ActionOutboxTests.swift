import GRDB
import os
import XCTest
@testable import WatchtowerKit

/// ActionOutbox contract: enqueue writes the relay record BEFORE the pending
/// overlay row (transport throw → no phantom overlay), echoes resolve or fail
/// the overlay, and the silent-pending sweep locally fails rows the desktop
/// never echoed (Plan 3 notes: undecodable actions get no echo, ever).
final class ActionOutboxTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeFixtures(
        clock: OSAllocatedUnfairLock<Date>? = nil
    ) throws -> (transport: InMemoryCloudTransport, store: ReplicaStore, outbox: ActionOutbox) {
        let transport = InMemoryCloudTransport()
        let store = try ReplicaStore.inMemory()
        let frozen = base
        let outbox = ActionOutbox(transport: transport, store: store) {
            clock?.withLock { $0 } ?? frozen
        }
        return (transport, store, outbox)
    }

    private func relayRecords(_ transport: InMemoryCloudTransport) async throws -> [CloudRecord] {
        try await transport.changes(in: .relay, since: nil).changed
    }

    private func decodeAction(_ record: CloudRecord) throws -> ActionRequestPayload {
        try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
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

    func testEnqueueTransportThrowLeavesNoPendingRow() async throws {
        let store = try ReplicaStore.inMemory()
        let outbox = ActionOutbox(transport: ThrowingSaveTransport(), store: store)

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
