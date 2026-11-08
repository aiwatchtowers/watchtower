import WatchtowerE2ETesting
import XCTest
@testable import WatchtowerSync

/// The feed's ordered half (relay client Phase 1, Task 7): a final ordered echo is deleted under its version, the
/// hub's controls are read once and deleted (`resend_from`, `transport_switch_rejected`) or left in the mailbox
/// (`transport_switched`, `hub_on_relay`, unknown kinds; Ruling 9), and a delete gets one try and never fails the
/// cycle (Ruling 8).
extension RelayFeedTests {

    // MARK: - Echo deletes

    func testAFinalOrderedEchoIsDeletedUnderItsSeq() async throws {
        let rig = try await OrderedRig.make()
        _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await rig.outbox.flush()
        try await rig.hub.sync()
        let records = try await rig.mailbox()
        let echo = try XCTUnwrap(records.first { $0.recordName == (try? rig.wire(1)) })

        let routed = try await rig.feed.pollOnce()

        XCTAssertEqual(routed, 1)
        let deletes = await rig.recorder.conditionalDeletes
        XCTAssertEqual(deletes, [.init(names: [try rig.wire(1)], expects: [.seq(try XCTUnwrap(echo.recordSeq))])])
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty)
        XCTAssertTrue(try rig.rows().isEmpty)
    }

    func testANonFinalEchoStays() async throws {
        let rig = try await OrderedRig.make()
        let id = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await rig.outbox.flush()
        var held = try XCTUnwrap(try rig.store.pendingActions().first).action
        held.status = .held
        try await rig.hub.hub.save([CloudRecordFactory.orderedRecord(
            for: held, actionSeq: 1, deviceID: TestE2E.deviceID, modifiedAt: OrderedRig.base)])

        _ = try await rig.feed.pollOnce()

        let deletes = await rig.recorder.conditionalDeletes
        XCTAssertTrue(deletes.isEmpty)
        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(1)])
        XCTAssertEqual(try rig.rows().map(\.actionID), [id])
    }

    func testALegacyEchoIsNeverDeleted() async throws {
        let rig = try await OrderedRig.make(ordered: false)
        let id = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        var echo = try XCTUnwrap(try rig.store.pendingActions().first).action
        echo.status = .applied
        try await rig.hub.hub.save([CloudRecordFactory.record(for: echo, modifiedAt: OrderedRig.base)])

        _ = try await rig.feed.pollOnce()

        XCTAssertTrue(try rig.store.pendingActions().isEmpty, "today's path still applies it")
        let calls = await rig.recorder.calls
        XCTAssertFalse(calls.contains { if case .delete = $0 { return true } else { return false } })
        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.phone.wireName(plain: "action-\(id)", zone: .relay)])
    }

    // MARK: - Controls

    func testResendFromIsHandledOnceAndDeleted() async throws {
        let rig = try await OrderedRig.make()
        try await rig.insert()
        try await rig.insert()
        _ = try await rig.outbox.flush()
        let resend = await rig.hub.control(.resendFrom, seq: 1)
        try await rig.hub.writeControl(resend)
        let before = await rig.recorder.conditionalSaves.count

        _ = try await rig.feed.pollOnce()

        let saves = await rig.recorder.conditionalSaves
        XCTAssertEqual(
            saves.dropFirst(before).map(\.names), [[try rig.wire(1)], [try rig.wire(2)]], "both written again")
        XCTAssertTrue(try rig.store.isControlHandled(id: resend.id))
        let mailbox = try await rig.mailboxNames()
        XCTAssertFalse(mailbox.contains(try rig.wire(resend)))

        // The second copy of the same control: deleted unread.
        try await rig.hub.writeControl(resend, expect: .none)
        let handled = await rig.recorder.conditionalSaves.count
        _ = try await rig.feed.pollOnce()
        let after = await rig.recorder.conditionalSaves.count
        XCTAssertEqual(after, handled, "no second resend")
        let afterCopy = try await rig.mailboxNames()
        XCTAssertFalse(afterCopy.contains(try rig.wire(resend)))
    }

    /// Carry-over 1: a `resend_from` whose handling throws (`noHubID`) fails the cycle, so the token stays and the
    /// same batch replays: the hub writes one per gap, and a lost one stalls the order.
    func testAResendFromWhoseHandlingThrowsKeepsTheToken() async throws {
        let rig = try await OrderedRig.make(hubID: nil)
        try await rig.insert()
        _ = try await rig.outbox.flush()
        let resend = await rig.hub.control(.resendFrom, seq: 1)
        try await rig.hub.writeControl(resend)
        let token = try rig.store.relayToken()

        do {
            _ = try await rig.feed.pollOnce()
            XCTFail("a resend_from that cannot be handled fails the cycle")
        } catch ActionOutboxError.noHubID {}

        XCTAssertEqual(try rig.store.relayToken(), token)
        XCTAssertFalse(try rig.store.isControlHandled(id: resend.id))
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.contains(try rig.wire(resend)))

        await rig.outbox.setHubID(TestE2E.hubID.uuidString)
        let before = await rig.recorder.conditionalSaves.count
        _ = try await rig.feed.pollOnce()
        let saves = await rig.recorder.conditionalSaves
        XCTAssertEqual(saves.dropFirst(before).map(\.names), [[try rig.wire(1)]], "the replayed resend_from ran")
        XCTAssertTrue(try rig.store.isControlHandled(id: resend.id))
        let afterLink = try await rig.mailboxNames()
        XCTAssertFalse(afterLink.contains(try rig.wire(resend)))
    }

    func testAControlNamingAnotherDeviceIsDropped() async throws {
        let rig = try await OrderedRig.make()
        try await rig.insert()
        _ = try await rig.outbox.flush()
        let otherPhone = await rig.hub.control(.resendFrom, seq: 1, deviceID: TestE2E.strangerDeviceID.uuidString)
        let otherHub = await rig.hub.control(.resendFrom, seq: 1, hubID: UUID().uuidString)
        try await rig.hub.writeControl(otherPhone)
        try await rig.hub.writeControl(otherHub)
        let before = await rig.recorder.conditionalSaves.count

        _ = try await rig.feed.pollOnce()

        let after = await rig.recorder.conditionalSaves.count
        XCTAssertEqual(after, before, "nothing written again")
        XCTAssertFalse(try rig.store.isControlHandled(id: otherPhone.id))
        XCTAssertFalse(try rig.store.isControlHandled(id: otherHub.id))
        let names = try await rig.mailboxNames()
        XCTAssertFalse(names.contains(try rig.wire(otherPhone)))
        XCTAssertFalse(names.contains(try rig.wire(otherHub)))
    }

    /// As Go's `readControl`: an empty id, or a frame id other than `c-<id>`, is dropped and deleted, unread.
    func testAMalformedControlIsDropped() async throws {
        let rig = try await OrderedRig.make()
        try await rig.insert()
        _ = try await rig.outbox.flush()
        let noID = ControlPayload(
            id: "", kind: .resendFrom, deviceID: TestE2E.deviceID.uuidString, hubID: TestE2E.hubID.uuidString, seq: 1)
        let misnamed = await rig.hub.control(.resendFrom, seq: 1)
        let otherName = "c-\(UUID().uuidString)"
        try await rig.hub.writeControl(noID, frameID: "c-\(UUID().uuidString)")
        try await rig.hub.writeControl(misnamed, frameID: otherName)
        let before = await rig.recorder.conditionalSaves.count

        _ = try await rig.feed.pollOnce()

        let after = await rig.recorder.conditionalSaves.count
        XCTAssertEqual(after, before, "nothing written again")
        XCTAssertFalse(try rig.store.isControlHandled(id: misnamed.id))
        let deletes = await rig.recorder.conditionalDeletes
        XCTAssertEqual(deletes.flatMap(\.names).count, 2, "both deleted")
        let mailbox = try await rig.mailboxNames()
        XCTAssertFalse(mailbox.contains(try rig.phone.wireName(plain: otherName, zone: .relay)))
        XCTAssertEqual(mailbox, [try rig.wire(1)])
    }

    /// Ruling 9: `transport_switched`, `hub_on_relay` and unknown kinds stay in the mailbox, unhandled (Phase 3 reads
    /// them); `transport_switch_rejected` is read and deleted.
    func testUnknownControlKindsStayInTheMailbox() async throws {
        let rig = try await OrderedRig.make()
        let switched = await rig.hub.control(.transportSwitched)
        let onRelay = await rig.hub.control(.hubOnRelay)
        let future = await rig.hub.control(ControlKind(rawValue: "future_kind"))
        let rejected = await rig.hub.control(.transportSwitchRejected)
        for control in [switched, onRelay, future, rejected] {
            try await rig.hub.writeControl(control)
        }

        _ = try await rig.feed.pollOnce()

        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(switched), try rig.wire(onRelay), try rig.wire(future)])
        for control in [switched, onRelay, future] {
            XCTAssertFalse(try rig.store.isControlHandled(id: control.id), control.kind.rawValue)
        }
        XCTAssertTrue(try rig.store.isControlHandled(id: rejected.id))
        let logged = await rig.feed.loggedControlKinds
        XCTAssertEqual(logged, ["transport_switched", "hub_on_relay", "future_kind"])
    }

    /// Relay client Phase 3 Task 10: a well-formed `hub_on_relay` is told to the link flow (once per read) and stays
    /// in the mailbox; one for another hub is not told.
    func testHubOnRelayIsToldAndStaysInTheMailbox() async throws {
        let told = Counter()
        let rig = try await OrderedRig.make { await told.bump() }
        let onRelay = await rig.hub.control(.hubOnRelay)
        try await rig.hub.writeControl(onRelay)

        _ = try await rig.feed.pollOnce()

        let count = await told.value
        XCTAssertEqual(count, 1)
        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(onRelay)], "left for the transport follower")
        XCTAssertFalse(try rig.store.isControlHandled(id: onRelay.id))
    }

    /// Relay client Phase 3 (Phase 1 Ruling 9 ends): `transport_switched` and `hub_on_relay` reach the transport
    /// handler on the ordered and on the legacy path; once it returns true each is marked handled and deleted, and a
    /// second copy is deleted unread.
    func testSwitchedAndHubOnRelayReachTheHandler() async throws {
        for ordered in [true, false] {
            let rig = try await OrderedRig.make(ordered: ordered)
            let seen = ControlLog()
            await rig.feed.setTransportHandler { control in
                await seen.add(control)
                return true
            }
            let switched = ControlPayload(
                id: UUID().uuidString, kind: .transportSwitched, deviceID: TestE2E.deviceID.uuidString,
                hubID: TestE2E.hubID.uuidString, epoch: 2, target: "relay", by: TestE2E.deviceID.uuidString,
                at: OrderedRig.base, keybox: "sealed-keybox")
            let onRelay = await rig.hub.control(.hubOnRelay)
            try await rig.hub.writeControl(switched)
            try await rig.hub.writeControl(onRelay)

            _ = try await rig.feed.pollOnce()

            let handed = await seen.all
            XCTAssertEqual(handed.map(\.id), [switched.id, onRelay.id], "ordered: \(ordered)")
            XCTAssertEqual(handed.first?.keybox, "sealed-keybox", "the keybox reaches the handler")
            XCTAssertTrue(try rig.store.isControlHandled(id: switched.id))
            XCTAssertTrue(try rig.store.isControlHandled(id: onRelay.id))
            let mailbox = try await rig.mailboxNames()
            XCTAssertTrue(mailbox.isEmpty, "both deleted")

            try await rig.hub.writeControl(switched, expect: .none)
            _ = try await rig.feed.pollOnce()
            let again = await seen.all
            XCTAssertEqual(again.count, 2, "a second copy is not handed again")
            let afterCopy = try await rig.mailboxNames()
            XCTAssertTrue(afterCopy.isEmpty)
        }
    }

    /// A handler that cannot decide yet (false) leaves the control in the mailbox, unmarked; the next cycle hands it
    /// again.
    func testUnhandledSwitchedStaysInTheMailbox() async throws {
        let rig = try await OrderedRig.make()
        let answers = ControlLog()
        await rig.feed.setTransportHandler { control in
            await answers.add(control)
            return await answers.all.count > 1
        }
        let switched = await rig.hub.control(.transportSwitched)
        try await rig.hub.writeControl(switched)

        _ = try await rig.feed.pollOnce()

        XCTAssertFalse(try rig.store.isControlHandled(id: switched.id))
        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(switched)], "left for the next pass")
        let deletes = await rig.recorder.conditionalDeletes
        XCTAssertTrue(deletes.isEmpty)

        // The next pass hands it again, though nothing new came: this time it is decided.
        _ = try await rig.feed.pollOnce()
        let handed = await answers.all.map(\.id)
        XCTAssertEqual(handed, [switched.id, switched.id])
        XCTAssertTrue(try rig.store.isControlHandled(id: switched.id))
        let after = try await rig.mailboxNames()
        XCTAssertTrue(after.isEmpty)
    }

    /// Relay client Phase 3b Task 19: `transport_switch_rejected` reaches the rejection handler (the session's upgrade)
    /// with its reason and `retry_after_s`; once it returns true it is marked handled and deleted, and a second copy is
    /// deleted unread.
    func testSwitchRejectedReachesTheHandler() async throws {
        let rig = try await OrderedRig.make()
        let seen = ControlLog()
        await rig.feed.setRejectionHandler { control in
            await seen.add(control)
            return true
        }
        let rejected = ControlPayload(
            id: UUID().uuidString, kind: .transportSwitchRejected, deviceID: TestE2E.deviceID.uuidString,
            hubID: TestE2E.hubID.uuidString, reason: "too_soon", retryAfterS: 240)
        try await rig.hub.writeControl(rejected)

        _ = try await rig.feed.pollOnce()

        let handed = await seen.all
        XCTAssertEqual(handed.map(\.id), [rejected.id])
        XCTAssertEqual(handed.first?.reason, "too_soon")
        XCTAssertEqual(handed.first?.retryAfterS, 240)
        XCTAssertTrue(try rig.store.isControlHandled(id: rejected.id))
        let mailbox = try await rig.mailboxNames()
        XCTAssertTrue(mailbox.isEmpty, "deleted once handled")

        try await rig.hub.writeControl(rejected, expect: .none)
        _ = try await rig.feed.pollOnce()
        let again = await seen.all
        XCTAssertEqual(again.count, 1, "a second copy is not handed again")
        let afterCopy = try await rig.mailboxNames()
        XCTAssertTrue(afterCopy.isEmpty, "the second copy is deleted unread")
    }

    /// A rejection handler that cannot decide yet (false) leaves the rejection in the mailbox, unmarked; the next
    /// cycle hands it again.
    func testUnhandledRejectionStaysInTheMailbox() async throws {
        let rig = try await OrderedRig.make()
        let answers = ControlLog()
        await rig.feed.setRejectionHandler { control in
            await answers.add(control)
            return await answers.all.count > 1
        }
        let rejected = await rig.hub.control(.transportSwitchRejected)
        try await rig.hub.writeControl(rejected)

        _ = try await rig.feed.pollOnce()

        XCTAssertFalse(try rig.store.isControlHandled(id: rejected.id))
        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(rejected)], "left for the next pass")

        _ = try await rig.feed.pollOnce()
        let handed = await answers.all.map(\.id)
        XCTAssertEqual(handed, [rejected.id, rejected.id])
        XCTAssertTrue(try rig.store.isControlHandled(id: rejected.id))
        let after = try await rig.mailboxNames()
        XCTAssertTrue(after.isEmpty)
    }

    /// The phone's own `skip_to` reflects back through the shared zone: the hub reads and deletes it, never the phone.
    func testThePhonesOwnControlIsLeftForTheHub() async throws {
        let rig = try await OrderedRig.make()
        let skip = ControlPayload.skipTo(3, deviceID: TestE2E.deviceID, hubID: TestE2E.hubID)
        try await rig.phone.saveSealed([try await rig.phone.seal(CloudRecordFactory.record(for: skip, modifiedAt: OrderedRig.base))])

        _ = try await rig.feed.pollOnce()

        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(skip)])
        XCTAssertFalse(try rig.store.isControlHandled(id: skip.id))
        let deletes = await rig.recorder.conditionalDeletes
        XCTAssertTrue(deletes.isEmpty)
    }

    // MARK: - Ruling 8

    /// A refused delete is logged, the cycle succeeds and the token advances; the delete is not tried again.
    func testAFailedDeleteNeverFailsTheCycle() async throws {
        let rig = try await OrderedRig.make()
        _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await rig.outbox.flush()
        try await rig.hub.sync()
        await rig.inner.refuseNext(.unreachable, count: 1)
        let token = try rig.store.relayToken()

        let routed = try await rig.feed.pollOnce()

        XCTAssertEqual(routed, 1)
        XCTAssertNotEqual(try rig.store.relayToken(), token)
        XCTAssertTrue(try rig.rows().isEmpty, "the echo was applied")
        let mailbox = try await rig.mailboxNames()
        XCTAssertEqual(mailbox, [try rig.wire(1)], "the refused delete left the echo")

        _ = try await rig.feed.pollOnce()
        let deletes = await rig.recorder.conditionalDeletes
        XCTAssertEqual(deletes.count, 1, "one try per read")
    }

    // MARK: - A left transport's mailbox (sim rule 15)

    /// The mailbox on a transport the phone left: the hub's records the feed never read are handled first (the echo
    /// settles its row, the controls are marked), then everything left is deleted, the phone's own unechoed action
    /// included. An undecided transport control keeps the drain incomplete and stays; nothing is written there.
    func testDrainDeletesOwnLeftoversAfterHandlingHubRecords() async throws {
        let rig = try await OrderedRig.make()
        _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-41")
        _ = try await rig.outbox.flush()
        try await rig.hub.sync() // seq 1 applied: its echo waits unread
        _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
        _ = try await rig.outbox.flush() // seq 2: the phone's own leftover
        let rejected = await rig.hub.control(.transportSwitchRejected)
        let switched = await rig.hub.control(.transportSwitched)
        try await rig.hub.writeControl(rejected)
        try await rig.hub.writeControl(switched)
        let saves = await rig.recorder.conditionalSaves.count
        let log = ControlLog()

        let first = try await rig.feed.drainMailbox(over: rig.phone) { control in
            await log.add(control)
            return false
        }

        XCTAssertEqual(first, .incomplete, "the undecided transport control keeps the mailbox")
        let left = try await rig.mailboxNames()
        XCTAssertEqual(left, [try rig.wire(switched)])
        XCTAssertEqual(try rig.rows().map(\.actionSeq), [2], "seq 1 settled by its echo; seq 2 left to the new route")
        XCTAssertTrue(try rig.store.isControlHandled(id: rejected.id))
        XCTAssertFalse(try rig.store.isControlHandled(id: switched.id))

        let second = try await rig.feed.drainMailbox(over: rig.phone) { control in
            await log.add(control)
            return true
        }

        XCTAssertEqual(second, .drained)
        let drained = try await rig.mailboxNames()
        XCTAssertTrue(drained.isEmpty)
        XCTAssertTrue(try rig.store.isControlHandled(id: switched.id))
        let told = await log.all.map(\.id)
        XCTAssertEqual(told, [switched.id, switched.id], "only the transport control reaches the follower")
        let savesAfter = await rig.recorder.conditionalSaves.count
        XCTAssertEqual(savesAfter, saves, "a drain never writes")
        XCTAssertEqual(try rig.rows().map(\.actionSeq), [2])
    }

    /// The owner's ruling on review round 1: on CloudKit the drain keeps the phone's own `device` record (both hubs'
    /// cleanup keeps that lane); on the relay it goes with the rest (rule 15).
    func testADrainOnCloudKitKeepsTheDeviceRecord() async throws {
        for keeping in [true, false] {
            let rig = try await OrderedRig.make()
            let device = CloudRecord(
                recordName: "device-\(TestE2E.deviceID.uuidString)", zone: .relay, kind: RelayRecordKind.device.rawValue,
                modifiedAt: OrderedRig.base, payload: Data("{}".utf8))
            try await rig.phone.save([device])
            _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
            _ = try await rig.outbox.flush()
            let deviceWire = try rig.phone.wireName(plain: device.recordName, zone: .relay)

            let outcome = try await rig.feed.drainMailbox(over: rig.phone, keepingDeviceRecord: keeping) { _ in true }

            XCTAssertEqual(outcome, .drained, "keeping \(keeping)")
            let left = try await rig.mailboxNames()
            XCTAssertEqual(left, keeping ? [deviceWire] : [], "keeping \(keeping)")
        }
    }

    /// Relay client Phase 5: a merge reseals this phone's own rows and the transport it followed reads them first, so
    /// the copies left behind read as rolled back. The drain deletes them with the rest; it keeps them only while the
    /// device record stays.
    func testADrainDeletesOlderCopiesOfRecordsAlreadyReadNewer() async throws {
        for keeping in [false, true] {
            let rig = try await OrderedRig.make()
            _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-42")
            _ = try await rig.outbox.flush()
            let wire = try rig.wire(1)
            let seen = InMemoryRollbackGuard()
            try seen.record(wireName: wire, senderID: TestE2E.deviceID, epoch: 2, seq: 1)
            let side = SecureTransport(inner: rig.recorder, keys: try TestE2E.phone(store: rig.keys), rollback: seen)

            let outcome = try await rig.feed.drainMailbox(over: side, keepingDeviceRecord: keeping) { _ in true }

            XCTAssertEqual(outcome, .drained, "keeping \(keeping)")
            let left = try await rig.mailboxNames()
            XCTAssertEqual(left, keeping ? [wire] : [], "keeping \(keeping)")
        }
    }

    /// An `applied` echo the drain settles fires `onActionApplied` once, as a poll does (review round 1, F9).
    func testADrainFiresOnActionAppliedForASettledEcho() async throws {
        let fired = expectation(description: "onActionApplied")
        let count = Counter()
        let rig = try await OrderedRig.make(onActionApplied: { // swiftlint:disable:this trailing_closure
            await count.bump()
            fired.fulfill()
        })
        _ = try await rig.outbox.enqueue(kind: .targetDone, entityRecordName: "target-41")
        _ = try await rig.outbox.flush()
        try await rig.hub.sync()

        let outcome = try await rig.feed.drainMailbox(over: rig.phone) { _ in true }

        XCTAssertEqual(outcome, .drained)
        await fulfillment(of: [fired], timeout: 5)
        let fires = await count.value
        XCTAssertEqual(fires, 1)
    }
}

private actor Counter {
    private(set) var value = 0

    func bump() {
        value += 1
    }
}

private actor ControlLog {
    private(set) var all: [ControlPayload] = []

    func add(_ control: ControlPayload) {
        all.append(control)
    }
}
