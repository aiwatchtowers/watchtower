import Foundation
import WatchtowerHostedRelayTesting
@testable import WatchtowerSync
import XCTest

/// The Swift port of relay@3a99bd7 `sim/` (Task 9): the envelope's wire form and one action
/// over each leg. The sim twins of the Go `sim_interop_test.go` build on it (Tasks 10–11).
final class SimModelTests: HostedRelayScenarioCase {
    func testEnvelopeRoundTripsAsTheGoSimJSON() throws {
        let action = SimEnvelope(kind: SimEnvelope.kindAction, sender: "p1", epoch: 1, seq: 3, payload: "a3")
        XCTAssertEqual(String(bytes: action.marshal(), encoding: .utf8), #"{"kind":"action","sender":"p1","epoch":1,"seq":3,"payload":"a3"}"#)

        let full = SimEnvelope(
            kind: SimEnvelope.kindSwitched, sender: "mac", epoch: 2, seq: 9, payload: "x<&>\"\\\n",
            id: "mac-4", target: .cloudkit, reason: SimEnvelope.reasonUser, status: SimEnvelope.statusApplied,
            retryAfterMs: 120_000, by: "p1", atMs: 1_800_000_000_000)
        let fullJSON = #"{"kind":"transport_switched","sender":"mac","epoch":2,"seq":9,"payload":"x\u003c\u0026\u003e\"\\\n","#
            + #""id":"mac-4","target":"cloudkit","reason":"user","status":"applied","retry_after_ms":120000,"by":"p1","at_ms":1800000000000}"#
        XCTAssertEqual(String(bytes: full.marshal(), encoding: .utf8), fullJSON)
        XCTAssertEqual(try SimEnvelope.open(full.marshal()), full)
        XCTAssertEqual(try SimEnvelope.open(Data(fullJSON.utf8)), full)

        // kind and sender have no omitempty in Go; every other empty field is left out.
        XCTAssertEqual(String(bytes: SimEnvelope(kind: SimEnvelope.kindEcho).marshal(), encoding: .utf8), #"{"kind":"echo","sender":""}"#)
        XCTAssertEqual(try SimEnvelope.open(Data(#"{"kind":"epoch_ack"}"#.utf8)), SimEnvelope(kind: SimEnvelope.kindEpochAck))

        // Go 1.22+ writes \b and \f short; other control characters as \u00XX.
        let controls = SimEnvelope(kind: SimEnvelope.kindAction, payload: "\u{08}\u{0C}\u{01}")
        XCTAssertEqual(String(bytes: controls.marshal(), encoding: .utf8), #"{"kind":"action","sender":"","payload":"\b\f\u0001"}"#)
        // Go's Kind is a string: an unknown target is kept as sent.
        let unknown = #"{"kind":"transport_switched","sender":"mac","target":"pigeon"}"#
        let opened = try SimEnvelope.open(Data(unknown.utf8))
        XCTAssertNil(opened.target)
        XCTAssertEqual(opened.targetName, "pigeon")
        XCTAssertEqual(String(bytes: opened.marshal(), encoding: .utf8), unknown)
        // UnixMilli truncates.
        XCTAssertEqual(SimEnvelope.unixMilli(Date(timeIntervalSince1970: 1.9999)), 1_999)

        XCTAssertEqual(SimEnvelope.kindOf(Data("not json".utf8)), "?")
        XCTAssertEqual(SimEnvelope.kindOf(action.marshal()), "action")
        XCTAssertEqual(Sim.actionName(12), "a-12")
        XCTAssertEqual(Sim.controlName("p1-3"), "c-p1-3")
        XCTAssertEqual(Sim.markerName, "transport")
        XCTAssertEqual([SimKind.relay.rawValue, SimKind.cloudkit.rawValue], ["relay", "cloudkit"])
    }

    func testAPhoneActionReachesTheHubOverTheRelay() async throws {
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)

        let seq = await phone.act("a1")
        XCTAssertEqual(seq, 1)
        let waiting = try await world.relayMailbox(phone)
        XCTAssertEqual(waiting, ["a-1"], "the action waits in the relay mailbox")
        try await world.syncAll()

        let applied = await world.hub.applied(from: phone)
        let outbox = await phone.outbox
        let relayLeft = try await world.relayMailbox(phone)
        let cloudKitLeft = await world.cloudKitMailbox(phone)
        let phoneTransport = await phone.transport
        let hubTransport = await world.hub.transport
        XCTAssertEqual(applied, ["1:a1"], "applied once")
        XCTAssertEqual(outbox, [], "the echo took it out of the outbox")
        XCTAssertEqual(relayLeft, [], "the echo was deleted: the mailbox is empty")
        XCTAssertEqual(cloudKitLeft, [])
        XCTAssertEqual(phoneTransport, .relay)
        XCTAssertEqual(hubTransport, .relay)
    }

    func testAPhoneActionReachesTheHubOverCloudKit() async throws {
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)
        await phone.switchTransport(to: .cloudkit)
        try await world.syncAll()
        let phoneTransport = await phone.transport
        let hubTransport = await world.hub.transport
        let epoch = await phone.epoch
        XCTAssertEqual(phoneTransport, .cloudkit)
        XCTAssertEqual(hubTransport, .cloudkit)
        XCTAssertEqual(epoch, 2)

        // InMemoryCloudTransport's refusals hit conditional writes only: the action goes out conditionally.
        let mailbox = try XCTUnwrap(world.cloudKit.store(for: world.cloudKitZone(phone)))
        await mailbox.refuseNext(.rateLimited(retryAfter: nil), count: 1)
        await phone.act("a1")
        let unsent = await phone.outbox
        let refusedLeft = await world.cloudKitMailbox(phone)
        XCTAssertEqual(unsent, [1])
        XCTAssertEqual(refusedLeft, [], "the refused write left nothing")

        try await world.syncAll()
        let applied = await world.hub.applied(from: phone)
        let outbox = await phone.outbox
        let cloudKitLeft = await world.cloudKitMailbox(phone)
        let relayLeft = try await world.relayMailbox(phone)
        XCTAssertEqual(applied, ["1:a1"])
        XCTAssertEqual(outbox, [])
        XCTAssertEqual(cloudKitLeft, [], "the echo was deleted conditionally")
        XCTAssertEqual(relayLeft, [], "the phone emptied the relay mailbox it left")
    }

    func testAnUnavailableCloudKitLegRefusesUnreachable() async throws {
        let leg = SimCloudKitLeg(clock: ManualRelayClock())
        leg.addMailbox("ck/mac/p1")
        let item = SimSaveItem(name: "a-1", envelope: Data("x".utf8), expect: .absent)

        leg.setAvailable(false)
        XCTAssertFalse(leg.available())
        let refusedSave = await leg.save("ck/mac/p1", [item])
        let refusedDelete = await leg.delete("ck/mac/p1", [SimDeleteItem(name: "a-1", expect: .none)])
        XCTAssertEqual(refusedSave, [.refused(.unreachable)])
        XCTAssertEqual(refusedDelete, [.refused(.unreachable)])
        do {
            _ = try await leg.changes("ck/mac/p1", since: 0)
            XCTFail("changes must throw while CloudKit is down")
        } catch {
            XCTAssertTrue(error is SimUnavailable, "\(error)")
        }

        leg.setAvailable(true)
        XCTAssertTrue(leg.available())
        let saved = await leg.save("ck/mac/p1", [item])
        XCTAssertEqual(saved, [.saved(recordSeq: 1)])
        let changes = try await leg.changes("ck/mac/p1", since: 0)
        XCTAssertEqual(changes.changed.map(\.recordName), ["a-1"])
        XCTAssertEqual(changes.changed.first?.payload, Data("x".utf8))
        let unknown = await leg.save("ck/mac/p2", [item])
        XCTAssertEqual(unknown, [.refused(.permanent(code: "no_zone"))], "an unknown zone")
    }

    // MARK: - Server controls

    func testTheHubReceivesEntitlementExpiredNamingThePhone() async throws {
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)
        await phone.setOffline(true)
        await phone.act("a1")

        try await world.expireEntitlement(phone)
        let hubControls = await world.controlsDelivered(to: SimWorld.hubOwner)
        let phoneControls = await world.controlsDelivered(to: phone.id)
        XCTAssertEqual(hubControls, [SimControl(kind: .entitlementExpired, detail: phone.id)])
        XCTAssertEqual(phoneControls, [SimControl(kind: .entitlementExpired, detail: "")])

        // The Go `TestHubActsOnEntitlementControl`: the hub falls back on the control alone.
        try await world.syncAll()
        let hubTransport = await world.hub.transport
        XCTAssertEqual(hubTransport, .cloudkit)
        await phone.setOffline(false)
        try await world.syncAll()
        let phoneTransport = await phone.transport
        let applied = await world.hub.applied(from: phone)
        XCTAssertEqual(phoneTransport, .cloudkit)
        XCTAssertEqual(applied, ["1:a1"])
    }

    // MARK: - Fault seam

    func testEveryLegOfEveryDeviceHasAFaultSeam() async throws {
        let world = try await simWorld()
        let paying = try await world.addPhone(paying: true)
        let free = try await world.addPhone(paying: false)
        XCTAssertEqual(world.fault(SimWorld.hubOwner, .relay)?.kind, .relay)
        XCTAssertEqual(world.fault(SimWorld.hubOwner, .cloudkit)?.kind, .cloudkit)
        XCTAssertEqual(world.fault(paying.id, .relay)?.kind, .relay)
        XCTAssertEqual(world.fault(paying.id, .cloudkit)?.kind, .cloudkit)
        XCTAssertNil(world.fault(free.id, .relay), "a free phone has no relay leg")
        XCTAssertEqual(world.fault(free.id, .cloudkit)?.kind, .cloudkit)
    }

    func testFailControlsFailsEveryWriteButActions() async throws {
        let leg = SimCloudKitLeg(clock: ManualRelayClock())
        leg.addMailbox("ck/mac/p1")
        let faulty = SimFaulty(leg)
        faulty.failControls = true
        let control = await faulty.save("ck/mac/p1", [Sim.saveItem(Sim.controlName("p1-1"), SimEnvelope(kind: SimEnvelope.kindEpochAck))])
        let marker = await faulty.save("ck/mac/p1", [SimSaveItem(name: Sim.markerName, envelope: Data(), expect: .none)])
        let action = await faulty.save("ck/mac/p1", [Sim.saveItem(Sim.actionName(1), SimEnvelope(kind: SimEnvelope.kindAction, seq: 1))])
        XCTAssertEqual(control, [.refused(.unreachable)])
        XCTAssertEqual(marker, [.refused(.unreachable)])
        XCTAssertEqual(action, [.saved(recordSeq: 1)])

        // In a world: the hub's resend_from stays queued until its relay leg writes again.
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)
        await phone.loseNextWrite()
        await phone.act("a1")
        await phone.act("a2")
        let hubRelay = try XCTUnwrap(world.fault(SimWorld.hubOwner, .relay))
        hubRelay.failControls = true
        await world.hub.sync()
        let resends = await world.hub.resendRequests
        XCTAssertEqual(resends, [1])
        let held = try await world.relayMailbox(phone)
        XCTAssertEqual(held, ["a-2"], "no resend_from written")
        hubRelay.failControls = false
        try await world.syncAll()
        let applied = await world.hub.applied(from: phone)
        XCTAssertEqual(applied, ["1:a1", "2:a2"])
    }

    func testRefuseActionsRateLimitsTheNextActionWrites() async throws {
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)
        let relay = try XCTUnwrap(world.fault(phone.id, .relay))
        relay.refuseActions = 1
        await phone.act("a1")
        let unsent = await phone.outbox
        let mailbox = try await world.relayMailbox(phone)
        XCTAssertEqual(unsent, [1])
        XCTAssertEqual(mailbox, [], "the refused write left nothing")
        XCTAssertEqual(relay.refuseActions, 0)

        try await world.syncAll()
        let applied = await world.hub.applied(from: phone)
        XCTAssertEqual(applied, ["1:a1"], "the refused action goes out on the next pass")
    }

    func testHoldControlsKeepsControlsFromTheDevice() async throws {
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)
        await phone.setOffline(true)
        let hubRelay = try XCTUnwrap(world.fault(SimWorld.hubOwner, .relay))
        hubRelay.holdControls = true

        try await world.expireEntitlement(phone)
        await world.controlsDelivered(to: SimWorld.hubOwner)
        await world.hub.sync()
        let held = await world.hub.transport
        XCTAssertEqual(held, .relay, "the control has not reached the hub")
        XCTAssertEqual(hubRelay.pendingControls().count, 1, "held, not taken")

        hubRelay.holdControls = false
        await world.hub.sync()
        let released = await world.hub.transport
        XCTAssertEqual(released, .cloudkit)
    }

    /// The hub answers a request for its current transport with `transport_switched` in the same
    /// epoch (Go `handleSwitch`, `target == h.current`): the phone stops waiting after one pass.
    func testAskingForTheCurrentTransportIsAnswered() async throws {
        let world = try await simWorld()
        let phone = try await world.addPhone(paying: true)
        await phone.switchTransport(to: .relay)
        await world.hub.sync()
        await phone.sync()
        let pending = await phone.switchPending
        let transport = await phone.transport
        let epoch = await phone.epoch
        XCTAssertFalse(pending, "the answer ended the wait")
        XCTAssertEqual(transport, .relay)
        XCTAssertEqual(epoch, 1)
    }
}
