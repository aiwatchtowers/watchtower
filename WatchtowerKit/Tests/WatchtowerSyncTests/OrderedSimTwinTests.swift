import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// Kit twins of the relay sim's phone-side tests (`relay/sim/sim_test.go`, spec §11): the phone's ordered outbox and
/// relay feed against `OrderedHubFake` (the Go hub's order and control rules) over one `InMemoryCloudTransport`.
/// The hub-side twins and the transport-switch twins come with Phases 2–3.
final class OrderedSimTwinTests: XCTestCase {

    /// Rules 2 and 4: each action is applied once, in order; a stale copy of a3 is a repeat, echoed and not applied;
    /// the phone deletes every final echo, so the mailbox ends up empty.
    func testActionsAppliedInOrderOnce() async throws {
        let rig = try await OrderedRig.make()
        for _ in 0..<3 { _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42") }
        _ = try await rig.outbox.flush()
        let a3 = try XCTUnwrap(try rig.rows().last)

        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        var applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 2, 3])
        XCTAssertTrue(try rig.rows().isEmpty)
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty)

        // A stale copy of a3 comes back (another transport's leftover, say).
        try await rig.inner.save([CloudRecord(
            recordName: a3.wireName, zone: .relay, kind: WireKind.envelope, modifiedAt: OrderedRig.base,
            payload: a3.envelope)])
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 2, 3], "a repeat is never applied again")
        let afterRepeat = try await rig.mailboxNames()
        XCTAssertTrue(afterRepeat.isEmpty, "its echo was deleted too")
    }

    /// Rule 5: a2 never reaches the hub, which applies a1, holds a3 and asks `resend_from(2)` once; the phone writes
    /// a2 and a3 again with the same bytes, and the hub applies them in order.
    func testGapTriggersResendFrom() async throws {
        let rig = try await OrderedRig.make()
        for _ in 0..<3 { try await rig.insert() }
        _ = try await rig.outbox.flush()
        let envelopes = try rig.rows().map(\.envelope)
        // a2 is lost before the hub reads it.
        try await rig.inner.delete(recordNames: [try rig.wire(2)], in: .relay)

        try await rig.hub.sync()
        var applied = await rig.hub.applied
        XCTAssertEqual(applied, [1])
        try await rig.hub.sync()
        var resends = await rig.hub.resendsWritten
        XCTAssertEqual(resends, [2], "asked once per gap")

        let before = await rig.recorder.conditionalSaves.count
        _ = try await rig.feed.pollOnce()
        let saves = await rig.recorder.conditionalSaves
        let resent = saves.dropFirst(before)
        XCTAssertEqual(resent.map(\.names).prefix(1), [[try rig.wire(2)]], "the gap first, then on in order")
        XCTAssertTrue(resent.map(\.names).contains([try rig.wire(3)]))
        XCTAssertEqual(Array(try rig.rows().map(\.envelope)), Array(envelopes.dropFirst()), "the same bytes")

        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 2, 3])
        resends = await rig.hub.resendsWritten
        XCTAssertEqual(resends, [2])
        XCTAssertTrue(try rig.rows().isEmpty)
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty)
    }

    /// Rule 6: a2 was refused for good, so the phone no longer has it when the hub asks from 2: it writes
    /// `skip_to(3)`, a2 stays listed as Not delivered, and the hub continues from 3.
    func testSkipToMarksUndelivered() async throws {
        let rig = try await OrderedRig.make()
        let (a2, _) = try await refuseA2(rig)

        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        let queued = try rig.store.queuedControls()
        XCTAssertTrue(queued.isEmpty, "skip_to written")
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        let applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 3])
        let skips = await rig.hub.skipsHonoured
        XCTAssertEqual(skips, [3])
        XCTAssertEqual(try rig.rows().map(\.actionID), [a2])
        XCTAssertEqual(try rig.rows().first?.delivery, .undelivered)
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty)
    }

    /// Rule 1: a refused action write stops the flush there and is retried on the next pass, in order.
    func testRefusedActionWriteRetried() async throws {
        let rig = try await OrderedRig.make()
        try await rig.insert()
        _ = try await rig.outbox.flush()
        try await rig.insert()
        try await rig.insert()
        await rig.inner.refuseNext(.rateLimited(retryAfter: nil), count: 1)

        let refused = try await rig.outbox.flush()
        XCTAssertEqual(refused, OutboxFlushReport(written: 0, stoppedOn: .rateLimited(retryAfter: nil)))
        try await rig.hub.sync()
        var applied = await rig.hub.applied
        XCTAssertEqual(applied, [1])

        let retried = try await rig.outbox.flush()
        XCTAssertEqual(retried, OutboxFlushReport(written: 2))
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 2, 3])
        let resends = await rig.hub.resendsWritten
        XCTAssertTrue(resends.isEmpty, "no gap ever reached the hub")
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty)
    }

    /// Rule 7a: the phone's `skip_to` is refused once; it stays queued, a3 is not written past it, and the next pass
    /// writes it, so the hub continues.
    func testPhoneSkipToRetriedUntilWritten() async throws {
        let rig = try await OrderedRig.make()
        _ = try await refuseA2(rig)
        try await rig.hub.sync()
        await rig.inner.refuseNext(.unreachable, count: 1)

        _ = try await rig.feed.pollOnce()

        let control = try XCTUnwrap(try rig.store.queuedControls().first, "the refused skip_to stays queued")
        XCTAssertEqual(control.kind, .skipTo)
        try await rig.hub.sync()
        var applied = await rig.hub.applied
        XCTAssertEqual(applied, [1])

        let next = try await rig.outbox.flush()
        XCTAssertEqual(next.stoppedOn, nil)
        XCTAssertTrue(try rig.store.queuedControls().isEmpty)
        try await rig.hub.sync()
        _ = try await rig.feed.pollOnce()

        applied = await rig.hub.applied
        XCTAssertEqual(applied, [1, 3])
        let skips = await rig.hub.skipsHonoured
        XCTAssertEqual(skips, [3])
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty)
    }

    // MARK: - Helpers

    /// a1 and a3 written, a2 refused for good in between (listed Not delivered). Returns a2's id and seq.
    private func refuseA2(_ rig: OrderedRig) async throws -> (id: String, seq: UInt64) {
        try await rig.insert()
        _ = try await rig.outbox.flush()
        let a2 = try await rig.insert()
        await rig.inner.refuseNext(.permanent(code: "tooLarge"), count: 1)
        let refused = try await rig.outbox.flush()
        XCTAssertEqual(refused.undelivered, 1)
        try await rig.insert()
        _ = try await rig.outbox.flush()
        return a2
    }
}
