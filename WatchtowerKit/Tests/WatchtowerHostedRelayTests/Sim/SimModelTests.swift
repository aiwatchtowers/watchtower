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

        XCTAssertEqual(SimEnvelope.kindOf(Data("not json".utf8)), "?")
        XCTAssertEqual(SimEnvelope.kindOf(action.marshal()), "action")
        XCTAssertEqual(Sim.actionName(12), "a-12")
        XCTAssertEqual(Sim.controlName("p1-3"), "c-p1-3")
        XCTAssertEqual(Sim.markerName, "transport")
        XCTAssertEqual([SimKind.relay.rawValue, SimKind.cloudkit.rawValue], ["relay", "cloudkit"])
    }

    func testAPhoneActionReachesTheHubOverTheRelay() async throws {
        let world = try await SimWorld(backend: backend)
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
        let world = try await SimWorld(backend: backend)
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
}
