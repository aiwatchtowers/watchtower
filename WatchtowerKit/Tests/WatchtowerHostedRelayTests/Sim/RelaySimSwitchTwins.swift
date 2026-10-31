import Foundation
@testable import WatchtowerHostedRelay
import WatchtowerHostedRelayTesting
import WatchtowerRelayProto
@testable import WatchtowerSync
import XCTest

/// Twins of relay@3a99bd7 `sim/sim_interop_test.go`: the transport switch and the lapsed
/// subscription (Go names, line-by-line ports). The Go `newWorld(t, n)` is `simWorld()` plus
/// `n` paying phones; `w.env.Stop`/`Start` are `relayDown`/`relayUp`, `ExpireEntitlement` and
/// `ExpireAccount` are `expireEntitlement`, `waitHubControl` is `controlsDelivered(to: hubOwner)`.
final class RelaySimSwitchTwins: HostedRelayScenarioCase {
    private static let fifteenDays = Duration.seconds(15 * 24 * 3600)

    func testSwitchToCloudKitDuringRelayOutage() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await a.act("a1")
        try await world.syncAll()
        await a.act("a2") // on the relay, never read by the hub
        await b.act("b1") // likewise

        try world.relayDown()
        await a.act("a3") // relay down: stays in the outbox
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await wantTransport("initiator", a.transport, .cloudkit)
        await wantTransport("second phone before 60 s", b.transport, .relay)
        await wantApplied(world, a, "1:a1", "2:a2", "3:a3")
        await wantApplied(world, b)
        for applied in await world.hub.appliedActions where applied.seq >= 2 && applied.epoch != 1 {
            XCTFail("old-epoch action applied as \(applied); it was sealed in epoch 1")
        }
        let hubEpoch = await world.hub.epoch
        let phoneEpoch = await a.epoch
        XCTAssertEqual([hubEpoch, phoneEpoch], [2, 2], "epochs hub, phone")

        world.advance(.seconds(61))
        try await world.syncAll()
        await wantTransport("second phone after 60 s", b.transport, .cloudkit)
        await wantApplied(world, b, "1:b1")
        let outboxA = await a.outbox
        let outboxB = await b.outbox
        XCTAssertEqual(outboxA, [], "outbox of a")
        XCTAssertEqual(outboxB, [], "outbox of b")

        try await world.relayUp()
        try await world.syncAll()
        await wantApplied(world, a, "1:a1", "2:a2", "3:a3")
        await wantApplied(world, b, "1:b1")
        for phone in world.phones {
            let records = try await world.relayMailbox(phone)
            XCTAssertEqual(records, [], "relay mailbox of \(phone.id.prefix(6)) keeps records")
        }
        await a.act("a4")
        try await world.syncAll()
        await wantApplied(world, a, "1:a1", "2:a2", "3:a3", "4:a4")
    }

    func testSwitchToRelayRejectedWithin5Min() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)

        world.advance(.seconds(60))
        await a.switchTransport(to: .relay)
        await a.act("a1") // the phone has not left CloudKit
        try await world.syncAll()
        let retryAfter = await a.switchRejected
        XCTAssertEqual(retryAfter, 4 * 60, "retry_after")
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await wantTransport("phone", a.transport, .cloudkit)
        await wantApplied(world, a, "1:a1")
        // Both copies of the request and of the answer are gone: each recipient deleted the second
        // copy as soon as it had read the first.
        let relayLeft = try await world.relayMailbox(a)
        XCTAssertEqual(relayLeft, [], "left on relay")
        let cloudKitLeft = await world.cloudKitMailbox(a)
        XCTAssertEqual(cloudKitLeft, [], "CloudKit mailbox keeps records")

        world.advance(.seconds(4 * 60))
        await a.switchTransport(to: .relay)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .relay)
        await wantTransport("phone", a.transport, .relay)
        let hubEpoch = await world.hub.epoch
        let phoneEpoch = await a.epoch
        XCTAssertEqual([hubEpoch, phoneEpoch], [3, 3], "epochs hub, phone")
        // Going back to CloudKit is never held back.
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
    }

    func testSecondPhoneFollowsSwitch() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await b.act("b1") // on the relay, not yet read
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await wantTransport("second phone", b.transport, .cloudkit)
        let by = await b.lastSwitch.by
        XCTAssertEqual(by, a.id, "switched by")
        let first = await world.hub.appliedActions
        XCTAssertEqual(first.map(\.epoch), [1], "b1 must be applied from the relay mailbox in epoch 1: \(first)")
        await b.act("b2")
        try await world.syncAll()
        await wantApplied(world, b, "1:b1", "2:b2")
        let second = await world.hub.appliedActions[1]
        XCTAssertEqual(second.epoch, 2, "b2 sealed in epoch")
    }

    func testOldEpochActionAfter14DaysResealed() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await a.setOffline(true)
        await a.act("a1") // sealed in epoch 1, waiting in the outbox
        await b.switchTransport(to: .cloudkit)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)

        world.advance(Self.fifteenDays)
        // The server's mailbox TTL has removed transport_switched from the relay meanwhile; the
        // returning phone learns of the switch from the hub's transport marker in its data zone.
        try await expireMailboxes(world)
        let left = try await world.relayMailbox(a)
        XCTAssertEqual(left, [], "mailbox TTL left records")
        await a.setOffline(false)
        try await world.syncAll()
        await wantTransport("returning phone", a.transport, .cloudkit)
        let by = await a.lastSwitch.by
        XCTAssertEqual(by, b.id, "switched by")
        await wantApplied(world, a, "1:a1")
        let applied = await world.hub.appliedActions
        XCTAssertEqual(applied.first?.epoch, 2, "applied \(applied), want resealed in epoch 2")
        let resends = await world.hub.resendRequests
        XCTAssertEqual(resends, [1], "resend_from requests")
    }

    func testNoCopiesLeftOnRelayAfterSwitch() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        await a.act("a1")
        try await world.syncAll()
        await a.act("a2")
        await world.hub.sync() // a2 echoed, the echo not yet read by the phone
        await a.switchTransport(to: .cloudkit)
        await a.act("a3") // still on the relay: the phone waits for the answer
        let before = try await world.relayMailbox(a)
        XCTAssertFalse(before.isEmpty, "expected records on the relay before the switch")
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await wantTransport("phone", a.transport, .cloudkit)
        await wantApplied(world, a, "1:a1", "2:a2", "3:a3")
        let relayLeft = try await world.relayMailbox(a)
        XCTAssertEqual(relayLeft, [], "left on relay")
        let cloudKitLeft = await world.cloudKitMailbox(a)
        XCTAssertEqual(cloudKitLeft, [], "CloudKit mailbox keeps records")
    }

    func testEntitlementExpiredFallsBackToCloudKit() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        await a.act("a1")
        try await world.syncAll()
        await a.act("a2") // on the relay, not yet read

        try await world.expireEntitlement(a)
        await waitForSwitchPending(world, a)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await wantTransport("phone", a.transport, .cloudkit)
        await wantApplied(world, a, "1:a1", "2:a2")
        let outbox = await a.outbox
        XCTAssertEqual(outbox, [], "outbox")
        let relayLeft = try await world.relayMailbox(a)
        XCTAssertEqual(relayLeft, [], "relay mailbox keeps records")
        await a.act("a3")
        try await world.syncAll()
        await wantApplied(world, a, "1:a1", "2:a2", "3:a3")
    }

    func testEntitlementExpiredOtherPayingPhoneKeepsHub() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await a.act("a1") // on the relay, not yet read by the hub
        try await world.expireEntitlement(a)
        await world.controlsDelivered(to: SimWorld.hubOwner)
        await waitForSwitchPending(world, a)
        await a.act("a2") // the relay refuses it now (ENTITLEMENT_INACTIVE): it stays unsent
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .relay)
        await wantTransport("other phone", b.transport, .relay)
        await wantTransport("lapsed phone", a.transport, .cloudkit)
        let toldOnRelay = await a.hubOnRelay
        XCTAssertTrue(toldOnRelay, "lapsed phone not told that the hub stays on the relay")
        await wantApplied(world, a)
        let undelivered = await a.undelivered
        XCTAssertEqual(undelivered, [SimUndelivered(seq: 1, payload: "a1"), SimUndelivered(seq: 2, payload: "a2")], "undelivered")
        let outbox = await a.outbox
        XCTAssertEqual(outbox, [], "outbox")
        let relayLeft = try await world.relayMailbox(a)
        XCTAssertEqual(relayLeft, [], "relay mailbox keeps records")
        // A retry from CloudKit is answered again: still undelivered, never silent.
        _ = try await a.retry(1)
        try await world.syncAll()
        let afterRetry = await a.undelivered
        XCTAssertEqual(afterRetry.count, 2, "undelivered after retry \(afterRetry)")
        XCTAssertEqual(afterRetry.last?.payload, "a1", "undelivered after retry \(afterRetry)")
        await b.act("b1")
        try await world.syncAll()
        await wantApplied(world, b, "1:b1")
    }

    func testLapsedPhoneActionAppliedBeforeHubKnewIsEchoed() async throws {
        let (world, phones) = try await newWorld(2)
        let a = phones[0]
        await a.act("a1")
        let hubControls = try XCTUnwrap(world.fault(SimWorld.hubOwner, .relay))
        hubControls.holdControls = true
        try await world.expireEntitlement(a)
        await world.hub.sync() // applies a1; its echo is refused
        await wantApplied(world, a, "1:a1")
        hubControls.holdControls = false
        await world.controlsDelivered(to: SimWorld.hubOwner)
        await waitForSwitchPending(world, a)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .relay)
        await wantTransport("lapsed phone", a.transport, .cloudkit)
        let outbox = await a.outbox
        let undelivered = await a.undelivered
        XCTAssertEqual(outbox, [], "outbox")
        XCTAssertEqual(undelivered, [], "undelivered")
        await wantApplied(world, a, "1:a1")
    }

    func testHubActsOnEntitlementControl() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        await a.setOffline(true)
        await a.act("a1")
        try await world.expireEntitlement(a)
        await world.controlsDelivered(to: SimWorld.hubOwner)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await a.setOffline(false)
        try await world.syncAll()
        await wantTransport("phone", a.transport, .cloudkit)
        await wantApplied(world, a, "1:a1")
    }

    func testStaleActionGetsSwitchAgain() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await a.setOffline(true)
        await b.switchTransport(to: .cloudkit)
        try await world.syncAll()
        try await expireMailboxes(world)
        var marker = Relay_V1_Delete()
        marker.zone = HostedRelayZones.data(mac: world.mac.deviceID)
        var item = Relay_V1_DeleteItem()
        item.name = Sim.markerName
        marker.items = [item]
        _ = try await world.mac.delete(marker)
        await a.setOffline(false)
        try await world.syncAll()
        await wantTransport("phone before acting", a.transport, .relay)
        await a.act("a1") // goes to the relay the hub left
        try await world.syncAll()
        await wantTransport("phone", a.transport, .cloudkit)
        await wantApplied(world, a, "1:a1")
    }

    func testMarkerLeadsReturningPhone() async throws {
        let (world, phones) = try await newWorld(2)
        let (a, b) = (phones[0], phones[1])
        await a.setOffline(true)
        await b.switchTransport(to: .cloudkit)
        try await world.syncAll()
        try await expireMailboxes(world)
        await a.setOffline(false)
        try await world.syncAll()
        await wantTransport("returning phone", a.transport, .cloudkit)
        let epoch = await a.epoch
        XCTAssertEqual(epoch, 2, "epoch")
    }

    func testStaleSwitchedIgnored() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        try world.relayDown()
        let stale = SimEnvelope(kind: SimEnvelope.kindSwitched, sender: world.mac.deviceID, epoch: 1, id: "stale", target: .relay)
        let saved = await world.cloudKit.save(
            world.cloudKitZone(a), [SimSaveItem(name: "c-stale", envelope: stale.marshal(), expect: .none)])
        XCTAssertEqual(saved.count, 1)
        if case .refused(let refusal) = saved.first { XCTFail("stale save refused: \(refusal)") }
        try await world.syncAll()
        await wantTransport("phone", a.transport, .cloudkit)
        let epoch = await a.epoch
        XCTAssertEqual(epoch, 2, "epoch")
    }

    func testSwitchedRetriedWhenBothMailboxesFailed() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        for kind in [SimKind.relay, .cloudkit] {
            try XCTUnwrap(world.fault(SimWorld.hubOwner, kind)).failControls = true
        }
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .cloudkit)
        await wantTransport("phone still waiting", a.transport, .relay)
        try XCTUnwrap(world.fault(SimWorld.hubOwner, .cloudkit)).failControls = false
        try await world.syncAll()
        await wantTransport("phone", a.transport, .cloudkit)
    }

    func testHubOnRelayTellsFreePhone() async throws {
        let (world, phones) = try await newWorld(1)
        let a = phones[0]
        await a.switchTransport(to: .cloudkit)
        try await world.syncAll()
        // Go builds the free phone by hand ("free-phone", CloudKit only, linked to the hub);
        // `addPhone(paying: false)` is that construction with a seeded id.
        let free = try await world.addPhone(paying: false)
        world.advance(.seconds(5 * 60))
        await a.switchTransport(to: .relay)
        try await world.syncAll()
        await wantTransport("hub", world.hub.transport, .relay)
        let told = await free.hubOnRelay
        XCTAssertTrue(told, "free phone not told that the hub moved to the relay")
    }

    // MARK: - Go helpers

    /// Go `newWorld(t, n)`: a Mac with `n` paying phones, everything on the relay in epoch 1.
    private func newWorld(_ count: Int) async throws -> (SimWorld, [SimPhone]) {
        let world = try await simWorld()
        for _ in 0..<count {
            _ = try await world.addPhone(paying: true)
        }
        return (world, world.phones)
    }

    /// Go `wantTransport`.
    private func wantTransport(
        _ name: String, _ got: SimKind, _ want: SimKind, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(got, want, "\(name) on \(got), want \(want)", file: file, line: line)
    }

    /// Go `wantApplied`.
    private func wantApplied(
        _ world: SimWorld, _ phone: SimPhone, _ want: String..., file: StaticString = #filePath, line: UInt = #line
    ) async {
        let got = await world.hub.applied(from: phone)
        XCTAssertEqual(got, want, "applied from \(phone.id.prefix(6))", file: file, line: line)
    }

    /// Go `w.env.ExpireMailboxes(15 * 24 * time.Hour)`: the TTL over every relay mailbox.
    private func expireMailboxes(_ world: SimWorld) async throws {
        var zones: [String] = []
        for phone in world.phones where world.relayClient(phone) != nil {
            zones.append(HostedRelayZones.mailbox(mac: world.mac.deviceID, phone: phone.id))
        }
        try await world.stand.expireMailboxes(zones, elapsed: Self.fifteenDays)
    }

    /// Go `waitFor(t, func() bool { a.Sync(); return a.SwitchPending() })`: the phone's passes
    /// until it heard of its lapsed subscription; 5 s cap, pumping the clock between passes.
    private func waitForSwitchPending(
        _ world: SimWorld, _ phone: SimPhone, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(5)
        while true {
            await phone.sync()
            if await phone.switchPending { return }
            guard Date() < deadline else {
                XCTFail("condition not met within 5 s", file: file, line: line)
                return
            }
            _ = world.clock.advanceToNextSleeper(shorterThan: Self.pumpedSleeps)
            await Task.yield()
        }
    }
}
