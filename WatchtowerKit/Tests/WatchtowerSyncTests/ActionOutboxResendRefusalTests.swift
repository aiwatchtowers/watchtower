import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// A row refused for good while the hub is asking for it (#1498). The hub asks once per gap, so nothing but the
/// phone's `skip_to` can move the order past that row: without it every later action of this phone is held for ever,
/// Interrupt and permission answers included.
final class ActionOutboxResendRefusalTests: XCTestCase {
    private static let routes: [HubRoute] = [.cloudKit(.private), .hostedRelay(macDeviceID: "mac-acme")]
    private let refused = TransportRefusal.permanent(code: "record_too_large")

    /// Rows 1, 2, 3 written; 2 lost before the hub read it, so the hub applied 1, held 3 and asked `resend_from(2)`.
    /// The phone has not read the ask yet.
    private func rigWithAnAskedGap(route: HubRoute = .cloudKit(.private)) async throws -> OrderedRig {
        let rig = try await OrderedRig.make(route: route)
        for _ in 0..<3 { try await rig.insert() }
        _ = try await rig.outbox.flush()
        try await rig.inner.delete(recordNames: [try rig.wire(2)], in: .relay)
        try await rig.hub.sync()
        let resends = await rig.hub.resendsWritten
        XCTAssertEqual(resends, [2])
        return rig
    }

    private func skips(_ rig: OrderedRig) async throws -> [ControlPayload] {
        try await rig.phone.changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.control.rawValue }
            .compactMap { try? RelayCoder.makeDecoder().decode(ControlPayload.self, from: $0.payload) }
            .filter { $0.kind == .skipTo }
    }

    private func row(_ rig: OrderedRig, seq: UInt64) throws -> OutboxRow? {
        try rig.rows().first { $0.actionSeq == seq }
    }

    /// One more action through the hub, end to end.
    private func actionGoesThrough(_ rig: OrderedRig, _ seq: UInt64, file: StaticString = #filePath, line: UInt = #line) async throws {
        _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await rig.outbox.flush()
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()
        let applied = await rig.hub.applied
        XCTAssertEqual(applied.last, seq, "action \(seq) must reach the hub's order", file: file, line: line)
    }

    func testARowRefusedForGoodOnAResendDoesNotStopLaterActions() async throws {
        for route in Self.routes {
            let rig = try await rigWithAnAskedGap(route: route)
            await rig.inner.refuseNext(refused, count: 1)

            _ = try await rig.feed.pollOnce()

            XCTAssertEqual(try row(rig, seq: 2)?.delivery, .undelivered)
            XCTAssertEqual(try row(rig, seq: 3)?.delivery, .sent)
            let skip = try await skips(rig)
            XCTAssertEqual(skip.map(\.seq), [3], "\(route)")
            XCTAssertEqual(skip.first?.deviceID, TestE2E.deviceID.uuidString)
            XCTAssertEqual(skip.first?.hubID, TestE2E.hubID.uuidString)

            try await rig.hub.sync()
            _ = try await rig.feed.pollOnce()
            var applied = await rig.hub.applied
            XCTAssertEqual(applied, [1, 3], "\(route)")

            try await actionGoesThrough(rig, 4)
            applied = await rig.hub.applied
            XCTAssertEqual(applied, [1, 3, 4], "\(route)")
            XCTAssertEqual(try rig.store.outboxRows([.undelivered]).map(\.actionSeq), [2], "still listed, with Retry")
        }
    }

    /// Permission answers and Interrupt keep their Not delivered row, message and Retry; only the order moves on.
    func testAPermissionAnswerOrInterruptRefusedOnAResendStaysNotDelivered() async throws {
        for kind in [ActionKind.permissionAnswer, .sessionInterrupt] {
            let rig = try await OrderedRig.make()
            try await rig.insert()
            let id = try await rig.outbox.enqueue(kind: kind, entityRecordName: nil)
            try await rig.insert()
            _ = try await rig.outbox.flush()
            try await rig.inner.delete(recordNames: [try rig.wire(2)], in: .relay)
            try await rig.hub.sync()
            await rig.inner.refuseNext(refused, count: 1)

            _ = try await rig.feed.pollOnce()

            let listed = try XCTUnwrap(try rig.store.pendingActions().first { $0.id == id })
            XCTAssertEqual(listed.delivery, .undelivered)
            XCTAssertEqual(listed.undeliveredReason, .refused)
            XCTAssertEqual(listed.errorMessage, "Not delivered to your Mac.")
            let retried = try await rig.outbox.retry(id: id)
            XCTAssertNotNil(retried, "Retry is still there")
            try await rig.hub.sync()
            _ = try await rig.feed.pollOnce()
            _ = try await rig.outbox.flush()
            try await rig.hub.sync()
            let applied = await rig.hub.applied
            XCTAssertEqual(applied, [1, 3, 4], "\(kind)")
        }
    }

    /// Several rows refused in one pass: one skip past all of them, none past a row still live.
    func testTwoRowsRefusedInAPassGetOneSkipPastBoth() async throws {
        let rig = try await OrderedRig.make()
        for _ in 0..<4 { try await rig.insert() }
        _ = try await rig.outbox.flush()
        try await rig.inner.delete(recordNames: [try rig.wire(1), try rig.wire(2)], in: .relay)
        try await rig.hub.sync()
        await rig.inner.refuseNext(refused, count: 2)

        _ = try await rig.feed.pollOnce()

        let skip = try await skips(rig)
        XCTAssertEqual(skip.map(\.seq), [3])
        try await rig.hub.sync()
        let applied = await rig.hub.applied
        XCTAssertEqual(applied, [3, 4])
    }

    /// Killed after the ask was read and the row listed, before the skip was queued: the next process's first flush
    /// queues it from what the store kept.
    func testAKillBetweenTheRefusalAndTheSkipIsRepairedAfterARestart() async throws {
        let rig = try await rigWithAnAskedGap()
        let two = try XCTUnwrap(try row(rig, seq: 2))
        try rig.store.raiseResendFloor(2)
        try rig.store.markUndelivered(actionIDs: [two.actionID], reason: .refused, message: ActionOutbox.refusedMessage)

        let restarted = ActionOutbox(
            transport: rig.phone, store: rig.store, deviceID: TestE2E.deviceID.uuidString) { OrderedRig.base }
        await restarted.setHubID(TestE2E.hubID.uuidString)
        _ = try await restarted.flush()

        let skip = try await skips(rig)
        XCTAssertEqual(skip.map(\.seq), [3])
        try await rig.hub.sync()
        let applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 3])
    }

    /// Killed after the ask was read, before the row's write: it is refused again after the restart and the skip follows.
    func testAKillBeforeTheRefusalIsRefusedAgainAndSkipped() async throws {
        let rig = try await rigWithAnAskedGap()
        try rig.store.raiseResendFloor(2)
        _ = try rig.store.requeue(fromSeq: 2)
        await rig.inner.refuseNext(refused, count: 1)

        let restarted = ActionOutbox(
            transport: rig.phone, store: rig.store, deviceID: TestE2E.deviceID.uuidString) { OrderedRig.base }
        await restarted.setHubID(TestE2E.hubID.uuidString)
        _ = try await restarted.flush()

        let skip = try await skips(rig)
        XCTAssertEqual(skip.map(\.seq), [3])
    }

    /// A transient stop right after the refusal: the row is listed, the pass stops, the next pass writes the skip.
    func testATransientStopAfterTheRefusalLeavesTheSkipToTheNextPass() async throws {
        let rig = try await rigWithAnAskedGap()
        await rig.inner.refuseNext(refused, count: 1) // row 2
        await rig.inner.refuseNext(.unreachable, count: 1) // row 3

        _ = try await rig.feed.pollOnce()
        var skip = try await skips(rig)
        XCTAssertTrue(skip.isEmpty)
        XCTAssertEqual(try row(rig, seq: 2)?.delivery, .undelivered)

        _ = try await rig.outbox.flush()
        skip = try await skips(rig)
        XCTAssertEqual(skip.map(\.seq), [3])
    }

    /// The skip's own write is refused: it stays queued, once, and the next pass writes it, on either kind of refusal.
    func testARefusedSkipIsWrittenByALaterPassOnce() async throws {
        for refusal in [TransportRefusal.unreachable, .permanent(code: "forbidden")] {
            let rig = try await rigWithAnAskedGap()
            let two = try XCTUnwrap(try row(rig, seq: 2))
            try rig.store.raiseResendFloor(2)
            try rig.store.markUndelivered(actionIDs: [two.actionID], reason: .refused, message: ActionOutbox.refusedMessage)
            await rig.inner.refuseNext(refusal, count: 1)

            _ = try await rig.outbox.flush()
            XCTAssertEqual(try rig.store.queuedControls().map(\.kind), [.skipTo], "\(refusal)")
            XCTAssertNil(try rig.store.resendFloor(), "the queue holds it now: no second skip")

            _ = try await rig.outbox.flush()
            XCTAssertTrue(try rig.store.queuedControls().isEmpty)
            let skip = try await skips(rig)
            XCTAssertEqual(skip.map(\.seq), [3], "\(refusal)")
        }
    }

    /// A skip lost after it was written (the relay's TTL): the hub's later ask gets a new one.
    func testASkipLostAfterItsWriteIsWrittenAgainWhenTheHubAsksAgain() async throws {
        let rig = try await rigWithAnAskedGap()
        await rig.inner.refuseNext(refused, count: 1)
        _ = try await rig.feed.pollOnce()
        let names = try await skips(rig).map { try rig.wire($0) }
        XCTAssertEqual(names.count, 1)
        try await rig.inner.delete(recordNames: names, in: .relay)

        try await rig.outbox.resendFrom(2)

        let again = try await skips(rig)
        XCTAssertEqual(again.map(\.seq), [3])
    }

    /// The keychain locks between the refusal and the skip's seal: the pass does not fail and the next one seals it.
    func testALockedKeychainLeavesTheSkipToALaterPass() async throws {
        let keys = try TestE2E.phoneStore()
        let inner = InMemoryCloudTransport()
        let phone = TestE2E.phoneTransport(try TestE2E.phone(store: keys), inner: inner)
        let store = try ReplicaStore.inMemory(opener: TestE2E.opener(store: keys))
        let outbox = ActionOutbox(transport: phone, store: store, deviceID: TestE2E.deviceID.uuidString) { OrderedRig.base }
        try await outbox.enableOrderedActions()
        await outbox.setHubID(TestE2E.hubID.uuidString)
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        await outbox.drain()
        let first = try XCTUnwrap(try store.outboxRows([.sent]).first)
        try store.raiseResendFloor(1)
        try store.markUndelivered(actionIDs: [first.actionID], reason: .refused, message: ActionOutbox.refusedMessage)

        keys.isLocked = true
        _ = try await outbox.flush()
        XCTAssertTrue(try store.queuedControls().isEmpty)

        keys.isLocked = false
        _ = try await outbox.flush()
        let written = try await phone.changes(in: .relay, since: nil).changed
            .filter { $0.kind == RelayRecordKind.control.rawValue }
        XCTAssertEqual(written.count, 1)
    }

    /// A newer action committed while the resend's flush runs: the skip stops at the first row still live, never past it.
    func testANewerActionDuringTheResendIsNotSkipped() async throws {
        let rig = try await rigWithAnAskedGap()
        await rig.inner.refuseNext(refused, count: 1)
        let outbox = rig.outbox
        let saved = await rig.recorder.conditionalSaves.count
        await rig.recorder.beforeSave(saved + 1) {
            _ = try? await outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        }

        _ = try await rig.feed.pollOnce()
        await rig.outbox.drain()
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        let applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 3, 4])
        XCTAssertEqual(try rig.store.outboxRows([.undelivered]).map(\.actionSeq), [2])
    }

    /// The only row is refused: the skip names the next seq, so the next action is the next in line.
    func testAResendThatEmptiedTheOutboxSkipsToTheNextSeq() async throws {
        let rig = try await OrderedRig.make()
        try await rig.insert()
        _ = try await rig.outbox.flush()
        await rig.inner.refuseNext(refused, count: 1)

        try await rig.outbox.resendFrom(1)

        let skip = try await skips(rig)
        XCTAssertEqual(skip.map(\.seq), [2])
    }

    /// 24 h without an answer lists a row the hub already asked for: the same skip closes that gap.
    func testAWithdrawnRowInAnAskedGapGetsASkip() async throws {
        let rig = try await rigWithAnAskedGap()
        // Row 2 is written again (the ask answered) and the hub never reads it.
        _ = try await rig.feed.pollOnce()
        let two = try XCTUnwrap(try row(rig, seq: 2))
        try rig.store.markUndelivered(actionIDs: [two.actionID], reason: .noAnswer, message: ActionOutbox.noAnswerMessage)

        _ = try await rig.outbox.flush()

        let skip = try await skips(rig)
        XCTAssertEqual(skip.map(\.seq), [3])
        XCTAssertEqual(try rig.store.pendingActions().first { $0.id == two.actionID }?.undeliveredReason, .noAnswer, "keeps its first reason")
    }

    /// A resend that works writes no skip, then or later: the final echo closes the ask.
    func testAFinalEchoClosesTheAskWithNoSkip() async throws {
        let rig = try await rigWithAnAskedGap()
        _ = try await rig.feed.pollOnce()
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()
        let applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 2, 3])

        try await actionGoesThrough(rig, 4)

        let skip = try await skips(rig)
        XCTAssertTrue(skip.isEmpty)
        let honoured = await rig.hub.skipsHonoured
        XCTAssertTrue(honoured.isEmpty)
    }

    /// A late copy of the skipped row is answered `expired`, as the Go hub does: never `applied`, which would drop the
    /// row from the owner's sight as if the action had run.
    func testALateCopyAfterTheSkipIsAnsweredExpiredAndNotDropped() async throws {
        let rig = try await rigWithAnAskedGap()
        let two = try XCTUnwrap(try row(rig, seq: 2))
        await rig.inner.refuseNext(refused, count: 1)
        _ = try await rig.feed.pollOnce()
        try await rig.hub.sync()

        try await rig.inner.save([CloudRecord(
            recordName: two.wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: OrderedRig.base,
            payload: two.envelope)])
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        let settled = try XCTUnwrap(try rig.store.pendingActions().first { $0.id == two.actionID })
        XCTAssertEqual(settled.state, .failed, "still in the owner's sight, with Retry")
        let applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 3])
    }
}
