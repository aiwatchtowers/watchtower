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
}
