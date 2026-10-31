import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Twins of the relay@3a99bd7 `sim/sim_interop_test.go` tests of the outbox, the order of
/// actions and control records (sim README rules 1–7a), with their Go names. Each body is a
/// line-by-line port; the Go `settle` is `syncAll`, `send` is `act`, `hubSync` is `hub.sync()`.
/// Not final: the interop suite (Task 12) reruns it on the stand.
class RelaySimOrderTwins: HostedRelayScenarioCase {
    /// Rules 2 and 4: every action applied once and in order; a stale copy of an applied action
    /// is dropped as a repeat and still echoed, and the mailbox ends up empty. Go runs the
    /// devices on their own (`Run` on live socket events) and waits; the Swift model has no run
    /// loop, so the twin drives the same passes with `syncAll`.
    func testActionsAppliedInOrderOnce() async throws {
        let world = try await simWorld()
        let phoneA = try await world.addPhone(paying: true)

        var want: [String] = []
        for index in 1...20 {
            await phoneA.act("a\(index)")
            want.append("\(index):a\(index)")
        }
        try await world.syncAll()
        let applied = await world.hub.applied(from: phoneA)
        let outbox = await phoneA.outbox
        XCTAssertEqual(applied.count, 20)
        XCTAssertEqual(outbox, [])
        XCTAssertEqual(applied, want)

        // A stale copy of action 3 (as left on another transport) shows up again.
        let stale = SimEnvelope(kind: SimEnvelope.kindAction, sender: phoneA.id, epoch: 1, seq: 3, payload: "a3")
        let client = try XCTUnwrap(world.relayClient(phoneA))
        var save = Relay_V1_Save()
        var item = Relay_V1_SaveItem()
        item.record.zone = HostedRelayZones.mailbox(mac: world.mac.deviceID, phone: phoneA.id)
        item.record.name = Sim.actionName(3)
        item.record.envelope = stale.marshal()
        item.mustNotExist = true
        save.items = [item]
        _ = try await client.save(save)
        let waiting = try await world.relayMailbox(phoneA)
        XCTAssertEqual(waiting, [Sim.actionName(3)], "the stale copy is in the mailbox")

        try await world.syncAll()
        let left = try await world.relayMailbox(phoneA)
        let reapplied = await world.hub.applied(from: phoneA)
        XCTAssertEqual(left, [])
        XCTAssertEqual(reapplied, want)
    }

    /// Rule 5: a missing seq stops the hub, which asks for resend_from(n+1); the phone resends
    /// from its outbox with the same bytes and everything is applied in order.
    func testGapTriggersResendFrom() async throws {
        let world = try await simWorld()
        let phoneA = try await world.addPhone(paying: true)
        await phoneA.act("a1")
        try await world.syncAll()
        await phoneA.loseNextWrite()
        await phoneA.act("a2") // never reaches the mailbox
        await phoneA.act("a3")
        await world.hub.sync()
        let held = await world.hub.applied(from: phoneA)
        XCTAssertEqual(held, ["1:a1"], "3 is held back, 2 is missing")
        let resends = await world.hub.resendRequests
        XCTAssertEqual(resends, [2], "resend_from requests")
        try await world.syncAll()
        let applied = await world.hub.applied(from: phoneA)
        let outbox = await phoneA.outbox
        let undelivered = await phoneA.undelivered
        XCTAssertEqual(applied, ["1:a1", "2:a2", "3:a3"])
        XCTAssertEqual(outbox, [])
        XCTAssertEqual(undelivered, [])
    }

    /// Rule 6: the phone no longer holds the requested action, answers skip_to and shows it as
    /// undelivered; a retry goes out as a new action at the end of the queue.
    func testSkipToMarksUndelivered() async throws {
        let world = try await simWorld()
        let phoneA = try await world.addPhone(paying: true)
        await phoneA.act("a1")
        try await world.syncAll()
        await phoneA.loseNextWrite()
        await phoneA.act("a2")
        await phoneA.forgetOutbox(2) // e.g. reinstall: the outbox lost it
        await phoneA.act("a3")
        try await world.syncAll()
        let skipped = await world.hub.applied(from: phoneA)
        XCTAssertEqual(skipped, ["1:a1", "3:a3"])
        let undelivered = await phoneA.undelivered
        XCTAssertEqual(undelivered, [SimUndelivered(seq: 2, payload: "a2")])
        let seq = try await phoneA.retry(2)
        XCTAssertEqual(seq, 4, "retry")
        try await world.syncAll()
        let applied = await world.hub.applied(from: phoneA)
        let still = await phoneA.undelivered
        XCTAssertEqual(applied, ["1:a1", "3:a3", "4:a2"])
        XCTAssertEqual(still, [], "still undelivered")
    }

    /// Rules 5 and 7a: a resend_from that could not be written is written later.
    func testHubResendFromRetriedUntilWritten() async throws {
        let world = try await simWorld()
        let phoneA = try await world.addPhone(paying: true)
        await phoneA.act("a1")
        try await world.syncAll()
        let hubRelay = try XCTUnwrap(world.fault(SimWorld.hubOwner, .relay))
        hubRelay.failControls = true
        await phoneA.loseNextWrite()
        await phoneA.act("a2")
        await phoneA.act("a3")
        try await world.syncAll()
        let stuck = await world.hub.applied(from: phoneA)
        XCTAssertEqual(stuck, ["1:a1"])
        hubRelay.failControls = false
        try await world.syncAll()
        let applied = await world.hub.applied(from: phoneA)
        XCTAssertEqual(applied, ["1:a1", "2:a2", "3:a3"])
    }

    /// Rules 6 and 7a: a skip_to that could not be written is written later.
    func testPhoneSkipToRetriedUntilWritten() async throws {
        let world = try await simWorld()
        let phoneA = try await world.addPhone(paying: true)
        await phoneA.act("a1")
        try await world.syncAll()
        await phoneA.loseNextWrite()
        await phoneA.act("a2")
        await phoneA.forgetOutbox(2)
        await phoneA.act("a3")
        let phoneRelay = try XCTUnwrap(world.fault(phoneA.id, .relay))
        phoneRelay.failControls = true
        try await world.syncAll()
        let stuck = await world.hub.applied(from: phoneA)
        XCTAssertEqual(stuck, ["1:a1"])
        phoneRelay.failControls = false
        try await world.syncAll()
        let applied = await world.hub.applied(from: phoneA)
        XCTAssertEqual(applied, ["1:a1", "3:a3"])
    }

    /// Rule 1: an action write the server refuses (rate limit, quota) is not counted as sent;
    /// it is written again on the next pass.
    func testRefusedActionWriteRetried() async throws {
        let world = try await simWorld()
        let phoneA = try await world.addPhone(paying: true)
        let phoneRelay = try XCTUnwrap(world.fault(phoneA.id, .relay))
        phoneRelay.refuseActions = 1
        await phoneA.act("a1")
        try await world.syncAll()
        let applied = await world.hub.applied(from: phoneA)
        XCTAssertEqual(applied, ["1:a1"])
    }
}
