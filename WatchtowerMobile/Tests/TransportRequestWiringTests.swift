import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Asking a Mac to go back to iCloud, the subscription's lapse and `hub_on_relay` (relay client Phase 4 Task 5): the
/// live `AppRoot` over the follower's bed (`Bed`: CloudKit in memory, the relay on `FakeHostedRelay`), a hub that offers
/// both transports and reads controls in order, and a scripted hub writing its answers.
@MainActor
final class TransportRequestWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString
    private let day: TimeInterval = 24 * 3600

    // MARK: - The two ways

    func testTheRequestGoesToICloudAndWhenReachableToRelayWithOneID() async throws {
        let (bed, session) = try await relayBed()

        let outcome = await session.requestTransport(reason: nil)
        await session.outbox.drain()

        XCTAssertEqual(outcome, .underWay)
        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(record.target, .cloudKit)
        XCTAssertNil(record.reason)
        XCTAssertTrue(record.iCloudWritten)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        let onRelay = try await bed.relayControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [record.controlID])
        XCTAssertEqual(onRelay.map(\.id), [record.controlID], "the same control id on both")
        XCTAssertEqual(onCloud.first?.target, "cloudkit")
        XCTAssertNil(onCloud.first?.reason)
        XCTAssertEqual(session.transportRequest, record)
    }

    func testAFailedRelayCopyDoesNotStopTheICloudRequest() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes() // the relay refuses writes (a lapse, an outage)

        let outcome = await session.requestTransport(reason: TransportFollowerPolicy.lapseReason)

        XCTAssertEqual(outcome, .underWay)
        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertTrue(record.iCloudWritten, "the iCloud copy got through")
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [record.controlID])
        let onRelay = try await bed.relayControls(.transportSwitch)
        XCTAssertTrue(onRelay.isEmpty)
        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [record.controlID], "kept in the outbox for the relay")
    }

    // MARK: - The lapse

    func testALapsedHubAsksOverICloudAndResumesAfterARelaunch() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await bed.cloud.refuse(.transient(code: "offline"))

        await session.lapseRelay()

        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(first.reason, "entitlement_expired")
        XCTAssertFalse(first.iCloudWritten)
        let none = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(none.isEmpty)
        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [first.controlID], "queued with the lapse's reason")

        // A relaunch with iCloud back: the same request goes on, not a new one.
        await bed.cloud.refuse(nil)
        try await bed.relaunch(self)
        let relaunched = try await booted(bed)
        await bed.root.resumeRelayUpgrades()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(record.controlID, first.controlID)
        XCTAssertTrue(record.iCloudWritten)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [first.controlID])
        XCTAssertEqual(onCloud.first?.reason, "entitlement_expired", "the hub spares its other phones")
        let again = try await queuedRequests(relaunched)
        XCTAssertTrue(again.isEmpty || again == [first.controlID], "the same id, never a second request")
        XCTAssertEqual(relaunched.transportRequest?.controlID, first.controlID)
    }

    /// Task 3's reviewer: the policy asks once per lapse (its flag stays set), so a lapse whose iCloud request was
    /// lost is re-sent from the record by the next pass or the next lapse notice.
    func testALostLapseRequestIsSentAgainByTheNextLapseNotice() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await bed.cloud.refuse(.transient(code: "offline"))
        await session.lapseRelay()
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertFalse(first.iCloudWritten)

        await bed.cloud.refuse(nil)
        await session.lapseRelay()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(record.controlID, first.controlID, "no second request")
        XCTAssertTrue(record.iCloudWritten)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [first.controlID])
        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [first.controlID], "still queued once")
    }

    func testAFailedICloudCopyIsRetriedOnTheNextPass() async throws {
        let (bed, session) = try await relayBed()
        await bed.cloud.refuse(.transient(code: "offline"))

        _ = await session.requestTransport(reason: nil)
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertFalse(first.iCloudWritten)

        await bed.cloud.refuse(nil)
        await bed.root.resumeRelayUpgrades()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertTrue(record.iCloudWritten)
        XCTAssertEqual(record.controlID, first.controlID)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.count, 1)
    }

    /// The only record a relay route holds: the upgrade got here, and a lapse has nothing to replace. Its slot is kept.
    func testALapseLeavesASwitchedUpgradeRecordAlone() async throws {
        let (bed, session) = try await relayBed()
        var link = try XCTUnwrap(bed.row()?.link)
        let slotted = bed.clock.now.addingTimeInterval(-3600)
        let upgrade = RelayUpgradeRecord(step: .switched, requestID: "old", slotSince: slotted, macDeviceID: bed.mac.deviceID)
        link.relayUpgrade = upgrade
        XCTAssertTrue(try bed.registry.updateLink(link))

        await session.lapseRelay()

        let after = try XCTUnwrap(try bed.row()?.link)
        XCTAssertNotNil(after.transportRequest)
        XCTAssertEqual(after.relayUpgrade, upgrade)
    }

    func testARelayOnlyHubIsNeverAskedOnALapse() async throws {
        let (bed, session) = try await relayBed(hubTransports: ["relay"])

        await session.lapseRelay()
        await session.outbox.drain()

        XCTAssertNil(try bed.row()?.link.transportRequest)
        XCTAssertEqual(try bed.row()?.link.transport, .relay, "the route stays")
        let queued = try await queuedRequests(session)
        XCTAssertTrue(queued.isEmpty)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(onCloud.isEmpty)
        let onRelay = try await bed.relayControls(.transportSwitch)
        XCTAssertTrue(onRelay.isEmpty)
    }

    func testARelayOnlyHubHasNoICloudCopy() async throws {
        let (bed, session) = try await relayBed(hubTransports: ["relay"])

        _ = await session.requestTransport(reason: nil)
        await session.outbox.drain()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertFalse(record.iCloudWritten)
        let saves = await bed.cloud.conditionalSaves
        XCTAssertTrue(saves.isEmpty, "no iCloud mailbox for a hub that has none")
        let onRelay = try await bed.relayControls(.transportSwitch)
        XCTAssertEqual(onRelay.map(\.id), [record.controlID], "only the first way")
        await bed.root.resumeRelayUpgrades()
        let still = await bed.cloud.conditionalSaves
        XCTAssertTrue(still.isEmpty)
    }

    func testALegacyHubIsNeverAsked() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try bed.session()
        await session.waitForBoot()
        try await bed.publishGrant(ordered: false)
        await bed.fetch(session)

        let outcome = await session.requestTransport(reason: nil)
        await session.lapseRelay()

        XCTAssertEqual(outcome, .refused(.notOrdered))
        XCTAssertNil(try bed.row()?.link.transportRequest)
        let queued = try await queuedRequests(session)
        XCTAssertTrue(queued.isEmpty)
        let saves = await bed.cloud.conditionalSaves
        XCTAssertTrue(saves.isEmpty)
    }

    func testARequestOnAnICloudRouteWritesNothing() async throws {
        let bed = try await Bed.make(self, on: .cloudKit, relayOff: true)
        let session = try await bed.orderedSession()

        let outcome = await session.requestTransport(reason: nil)
        await session.lapseRelay()
        await session.outbox.drain()

        XCTAssertEqual(outcome, .refused(.unavailable))
        XCTAssertNil(try bed.row()?.link.transportRequest)
        let queued = try await queuedRequests(session)
        XCTAssertTrue(queued.isEmpty)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(onCloud.isEmpty)
        XCTAssertFalse(bed.rootRelay.isBuilt, "an empty origin builds no relay object")
    }

    // MARK: - The day

    func testAClosedMacWaitsThenEndsAfterADay() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes() // the row stays queued: nothing reached the Mac
        _ = await session.requestTransport(reason: nil)
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)

        bed.clock.advance(23 * 3600)
        try await bed.relaunch(self)
        let relaunched = try await booted(bed)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.controlID, first.controlID)
        XCTAssertNil(try bed.row()?.link.transportRequest?.refusal, "23 h: still waiting")
        let outcomeAt23h = await relaunched.requestTransport(reason: nil)
        XCTAssertEqual(outcomeAt23h, .underWay)

        bed.clock.advance(3600)
        await bed.root.resumeRelayUpgrades()

        let ended = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(ended.refusal, .macNoAnswer)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(onCloud.isEmpty, "the iCloud copy is withdrawn")

        // Try Again starts a new record.
        let again = await relaunched.requestTransport(reason: ended.reason)
        XCTAssertEqual(again, .underWay)
        let fresh = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNotEqual(fresh.controlID, first.controlID)
        XCTAssertNil(fresh.refusal)
        XCTAssertEqual(fresh.at, bed.clock.now)
    }

    func testAnExpiredOwnerRequestWithdrawsItsQueuedRow() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes() // the relay never took it: the row is still queued
        _ = await session.requestTransport(reason: nil)
        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        let before = try await queuedRequests(session)
        XCTAssertEqual(before, [record.controlID])

        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()

        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .macNoAnswer)
        let after = try await queuedRequests(session)
        XCTAssertTrue(after.isEmpty)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(onCloud.isEmpty)
    }

    func testALapseAfterADayKeepsItsCopy() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await session.lapseRelay()
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)

        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()

        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .lapseNoAnswer)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [first.controlID], "the phone cannot use the relay either way")
        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [first.controlID])
    }

    func testTryAgainKeepsTheReason() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await session.lapseRelay()
        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        let ended = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(ended.refusal, .lapseNoAnswer)

        let outcome = await session.requestTransport(reason: ended.reason)

        XCTAssertEqual(outcome, .underWay)
        let fresh = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNotEqual(fresh.controlID, ended.controlID)
        XCTAssertEqual(fresh.reason, "entitlement_expired")
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.last?.reason, "entitlement_expired")
        XCTAssertEqual(onCloud.last?.id, fresh.controlID)
    }

    // MARK: - How it ends

    func testHubOnRelayEndsALapseRequest() async throws {
        let (bed, session) = try await relayBed()
        await session.lapseRelay()
        bed.relayOps.paying = false
        let control = try await bed.writeHubControl(.hubOnRelay, on: .relay)

        let second = try await bed.fetchAndFollow(session)

        XCTAssertTrue(try Bed.handled(second, control.id))
        let link = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(link.transport, .cloudKit)
        XCTAssertNil(link.transportRequest, "the request ends")
        XCTAssertEqual(link.hubOnRelayAt, bed.clock.now)
        XCTAssertEqual(second.hubOnRelayAt, bed.clock.now)
    }

    func testHubOnRelayIsKeptAndClearedByAMoveBack() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let first = try await bed.orderedSession()
        bed.relayOps.paying = false

        _ = try await bed.writeHubControl(.hubOnRelay, on: .cloudKit)
        await bed.fetch(first)
        XCTAssertEqual(try bed.row()?.link.hubOnRelayAt, bed.clock.now)
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)

        // A free phone told to follow the hub to the relay is the same fact.
        bed.clock.advance(10)
        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        await bed.fetch(first)
        XCTAssertEqual(try bed.row()?.link.hubOnRelayAt, bed.clock.now, "kept, and set again by the refused move")

        // Paying again, the hub moves to the relay with this phone: the route becomes relay and the flag clears.
        bed.relayOps.paying = true
        bed.clock.advance(10)
        try await bed.writeSwitch(target: .relay, epoch: 3, on: .cloudKit)
        _ = try await bed.fetchAndFollow(first)
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertNil(try bed.row()?.link.hubOnRelayAt)
    }

    func testTheMoveEndsTheRequest() async throws {
        let (bed, session) = try await relayBed()
        _ = await session.requestTransport(reason: nil)
        await session.outbox.drain()
        XCTAssertNotNil(try bed.row()?.link.transportRequest)

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        let second = try await bed.fetchAndFollow(session)

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.transportRequest)
        XCTAssertNil(second.transportRequest)
        XCTAssertNil(try bed.row()?.link.hubOnRelayAt)
    }

    func testAnAnswerForWhereItRunsEndsTheRequest() async throws {
        let (bed, session) = try await relayBed()
        _ = await session.requestTransport(reason: nil)
        await session.outbox.drain()
        let epoch = try XCTUnwrap(bed.root.newestEpoch(hubID: hubID))

        // The hub answers with the transport it already runs on, in the epoch the phone holds.
        let control = try await bed.writeSwitch(target: .relay, epoch: epoch, on: .relay)
        await bed.fetch(session)

        XCTAssertTrue(try Bed.handled(session, control.id))
        XCTAssertNil(try bed.row()?.link.transportRequest)
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
    }

    func testUnavailableAsksOnceMoreThenEnds() async throws {
        let (bed, session) = try await relayBed()
        _ = await session.requestTransport(reason: nil)
        await session.outbox.drain()
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)

        try await bed.writeRejection(RelayUpgrade.unavailable, retryAfter: 60, on: .relay)
        await bed.fetch(session)
        let waiting = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNil(waiting.refusal)
        XCTAssertEqual(waiting.retryAt, bed.clock.now.addingTimeInterval(60))

        bed.clock.advance(60)
        await bed.root.resumeRelayUpgrades()
        await session.outbox.drain()
        let second = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNotEqual(second.controlID, first.controlID, "a new request")
        XCTAssertTrue(second.askedAgain)
        let asked = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(asked.map(\.id), [first.controlID, second.controlID])

        try await bed.writeRejection(RelayUpgrade.unavailable, retryAfter: 60, on: .relay)
        await bed.fetch(session)
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .unavailable)
        bed.clock.advance(120)
        await bed.root.resumeRelayUpgrades()
        let after = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(after.count, 2, "only one automatic new request")
    }

    func testNotSupportedEndsTheRequest() async throws {
        let (bed, session) = try await relayBed()
        _ = await session.requestTransport(reason: nil)
        await session.outbox.drain()

        try await bed.writeRejection(RelayUpgrade.notSupported, on: .relay)
        await bed.fetch(session)

        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .notSupported)
    }

    func testRefusalsThatNeverAnswerARequestTowardICloudLeaveItWaiting() async throws {
        let (bed, session) = try await relayBed()
        _ = await session.requestTransport(reason: nil)
        await session.outbox.drain()

        for reason in [RelayUpgrade.tooSoon, RelayUpgrade.notPaying] {
            try await bed.writeRejection(reason, retryAfter: 30, on: .relay)
            await bed.fetch(session)
            let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
            XCTAssertNil(record.refusal, reason)
            XCTAssertNil(record.retryAt, reason)
        }
    }

    func testARejectionStillReachesAnUpgradeWhenNoRequestIsOpen() async throws {
        let (bed, session) = try await relayBed()
        XCTAssertNil(try bed.row()?.link.transportRequest)

        try await bed.writeRejection(RelayUpgrade.unavailable, retryAfter: 60, on: .relay)
        await bed.fetch(session)

        XCTAssertNil(try bed.row()?.link.transportRequest)
    }

    // MARK: - The mailbox

    func testAnOpenRequestReadsTheICloudMailboxWhileTheRelayAnswers() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes() // the relay answers every call but the Mac never reads the request there
        _ = await session.requestTransport(reason: nil)
        let reader = try XCTUnwrap(session.sideReader)

        // The hub read the iCloud copy and answers in the iCloud mailbox.
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)
        await reader.tick()
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.transportRequest)
        let pulls = await bed.sides.cloud.last?.pulls ?? 0
        XCTAssertGreaterThan(pulls, 0, "the iCloud mailbox was read")
    }

    func testTheICloudMailboxIsReadEveryThirtySecondsNotMore() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        _ = await session.requestTransport(reason: nil)
        let reader = try XCTUnwrap(session.sideReader)

        await reader.tick()
        await reader.tick()
        let once = await bed.sides.cloud.last?.pulls ?? 0
        bed.clock.advance(31)
        await reader.tick()
        let twice = await bed.sides.cloud.last?.pulls ?? 0

        XCTAssertEqual(once, 1)
        XCTAssertEqual(twice, 2)
    }

    func testNoRequestMeansNoICloudRead() async throws {
        let (bed, session) = try await relayBed()
        let reader = try XCTUnwrap(session.sideReader)

        await reader.tick()

        XCTAssertTrue(bed.sides.cloud.isEmpty, "the relay answers and nothing is asked: iCloud is not touched")
    }

    // MARK: - Fix round 1

    func testANewerEpochSwitchToCloudKitClearsHubOnRelayOnAnICloudPhone() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let session = try await bed.orderedSession()
        bed.relayOps.paying = false
        _ = try await bed.writeHubControl(.hubOnRelay, on: .cloudKit)
        await bed.fetch(session)
        XCTAssertNotNil(try bed.row()?.link.hubOnRelayAt)

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)
        await bed.fetch(session)

        XCTAssertNil(try bed.row()?.link.hubOnRelayAt, "the Mac is back on iCloud")
    }

    func testANewerEpochMarkerTowardCloudKitClearsHubOnRelayOnAnICloudPhone() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let session = try await bed.orderedSession()
        bed.relayOps.paying = false
        _ = try await bed.writeHubControl(.hubOnRelay, on: .cloudKit)
        await bed.fetch(session)
        XCTAssertNotNil(try bed.row()?.link.hubOnRelayAt)

        try await bed.writeMarker(target: .cloudKit, epoch: 2)
        await bed.fetch(session)

        XCTAssertNil(try bed.row()?.link.hubOnRelayAt)
    }

    func testARepeatedLapseNoticeKeepsAClosedLapseRefusal() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await session.lapseRelay()
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)
        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .lapseNoAnswer)

        await session.lapseRelay()
        await session.lapseRelay()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(record.controlID, first.controlID, "no new request")
        XCTAssertEqual(record.refusal, .lapseNoAnswer)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [first.controlID])
    }

    func testARepeatedLapseNoticeDoesNotLoopOnNotSupported() async throws {
        let (bed, session) = try await relayBed()
        await session.lapseRelay()
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)
        try await bed.writeRejection(RelayUpgrade.notSupported, on: .relay)
        await bed.fetch(session)
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .notSupported)

        await session.lapseRelay()
        await bed.fetch(session)
        await session.lapseRelay()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(record.controlID, first.controlID)
        XCTAssertEqual(record.refusal, .notSupported)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.count, 1)
    }

    func testALapseMayReplaceAnExpiredOwnerRequest() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        _ = await session.requestTransport(reason: nil)
        let owner = try XCTUnwrap(try bed.row()?.link.transportRequest)
        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .macNoAnswer)

        await session.lapseRelay()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNil(record.refusal)
        XCTAssertNotEqual(record.controlID, owner.controlID)
        XCTAssertEqual(record.reason, "entitlement_expired")
    }

    func testAKeptLapseCopyIsStillReadForTheAnswer() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await session.lapseRelay()
        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .lapseNoAnswer)
        let reader = try XCTUnwrap(session.sideReader)

        // The Mac is back, reads the kept copy and answers in the iCloud mailbox.
        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)
        await reader.tick()
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.transportRequest)
    }

    func testAnUnlinkInsideAPassWritesNoCopy() async throws {
        let (bed, session) = try await relayBed()
        let requester = try XCTUnwrap(session.transportRequester)
        // The unlink lands while the pass is between its queue step and its iCloud copy.
        requester.beforeCopy = { [bed, hubID] in
            await bed.root.linking.unlink(hubID)
        }

        _ = await session.requestTransport(reason: nil)

        XCTAssertNil(try bed.row())
        let saves = await bed.cloud.conditionalSaves
        XCTAssertTrue(saves.isEmpty, "nothing written for a link that is gone")
        XCTAssertTrue(bed.sides.cloud.isEmpty, "no store opened")
    }

    func testALapseJoiningAnOwnersRequestCarriesTheLapseReason() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        _ = await session.requestTransport(reason: nil)
        let owner = try XCTUnwrap(try bed.row()?.link.transportRequest)

        await session.lapseRelay()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(record.reason, "entitlement_expired")
        XCTAssertNotEqual(record.controlID, owner.controlID)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [record.controlID], "the owner's plain copy is withdrawn")
        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [record.controlID])

        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .lapseNoAnswer)
        let kept = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(kept.map(\.id), [record.controlID], "a lapse's copy stays")
    }

    // MARK: - Fix round 2

    func testARejectionReadOnICloudAfterALapseDayIsHeard() async throws {
        for (reason, expected) in [
            (RelayUpgrade.notSupported, TransportRequestRefusal.notSupported),
            (RelayUpgrade.unavailable, TransportRequestRefusal.unavailable)
        ] {
            let (bed, session) = try await relayBed()
            await session.outbox.holdFlushes()
            await session.lapseRelay()
            bed.clock.advance(25 * 3600)
            await bed.root.resumeRelayUpgrades()
            XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .lapseNoAnswer)
            let reader = try XCTUnwrap(session.sideReader)

            // The Mac is back, reads the kept copy and refuses in the iCloud mailbox.
            try await bed.writeRejection(reason, retryAfter: 60, on: .cloudKit)
            await reader.tick()

            XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, expected, reason)
            let pulls = await bed.sides.cloud.last?.pulls ?? 0
            bed.clock.advance(31)
            await reader.tick()
            let after = await bed.sides.cloud.last?.pulls ?? 0
            XCTAssertEqual(after, pulls, "a closed refusal is not polled any more")
        }
    }

    func testAJoiningLapseOnARelayOnlyHubLeavesTheOwnersRequestAlone() async throws {
        let (bed, session) = try await relayBed(hubTransports: ["relay"])
        await session.outbox.holdFlushes()
        _ = await session.requestTransport(reason: nil)
        let owner = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertTrue(owner.outboxQueued)

        await session.lapseRelay()

        XCTAssertEqual(try bed.row()?.link.transportRequest, owner)
        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [owner.controlID], "the row was not withdrawn")
    }

    func testTheLapseEndingClearsItsRequestAndWithdrawsTheCopy() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await session.lapseRelay()
        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.refusal, .lapseNoAnswer)

        await session.lapseEnded()

        XCTAssertNil(try bed.row()?.link.transportRequest)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(onCloud.isEmpty, "the Mac must not move now")
        let queued = try await queuedRequests(session)
        XCTAssertTrue(queued.isEmpty)

        // A later lapse asks again, with a new request.
        await session.lapseRelay()
        XCTAssertNotNil(try bed.row()?.link.transportRequest)
    }

    func testTheLapseEndingLeavesAnOwnersRequestAlone() async throws {
        let (bed, session) = try await relayBed()
        _ = await session.requestTransport(reason: nil)
        let owner = try XCTUnwrap(try bed.row()?.link.transportRequest)

        await session.lapseEnded()

        XCTAssertEqual(try bed.row()?.link.transportRequest, owner)
    }

    // MARK: - Unlink

    func testAnUnlinkDuringARequestWinsAndNothingIsWrittenAfter() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        await bed.cloud.refuse(.transient(code: "offline"))
        _ = await session.requestTransport(reason: nil)
        XCTAssertNotNil(try bed.row()?.link.transportRequest)

        await bed.root.linking.unlink(hubID)
        await bed.cloud.refuse(nil)
        await session.transportRequester?.resume()
        _ = await session.requestTransport(reason: nil)

        XCTAssertNil(try bed.row())
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(onCloud.isEmpty)
    }

    // MARK: - The record

    func testALinkRecordWithAnUnreadableRequestReadsAsAbsent() throws {
        var link = LinkRecord(
            hubID: hubID, macName: "Work Mac", scope: .private, ownerName: "", userRecordName: "_owner-acme", nonce: "n",
            dataShareURL: nil, relayShareURL: nil)
        link.transportRequest = TransportRequestRecord(target: .cloudKit, controlID: "C", reason: nil, at: Date(timeIntervalSince1970: 5))
        link.hubOnRelayAt = Date(timeIntervalSince1970: 7)
        let data = try JSONEncoder().encode(link)
        let back = try JSONDecoder().decode(LinkRecord.self, from: data)
        XCTAssertEqual(back, link)

        var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["transportRequest"] = ["target": "a transport from the future"]
        let changed = try JSONSerialization.data(withJSONObject: json)
        let tolerant = try JSONDecoder().decode(LinkRecord.self, from: changed)
        XCTAssertNil(tolerant.transportRequest)
        XCTAssertEqual(tolerant.hubOnRelayAt, link.hubOnRelayAt)

        // A CloudKit link that never asked carries neither key.
        let plain = try JSONEncoder().encode(LinkRecord(
            hubID: hubID, macName: "Work Mac", scope: .private, ownerName: "", userRecordName: "_owner-acme", nonce: "n",
            dataShareURL: nil, relayShareURL: nil))
        let text = try XCTUnwrap(String(bytes: plain, encoding: .utf8))
        XCTAssertFalse(text.contains("transportRequest"))
        XCTAssertFalse(text.contains("hubOnRelayAt"))
    }

    // MARK: - Helpers

    /// A hub on the relay that reads controls in order, its session booted.
    private func relayBed(hubTransports: [String] = ["cloudkit", "relay"]) async throws -> (Bed, HubSession) {
        let bed = try await Bed.make(self, on: .relay, hubTransports: hubTransports)
        let session = try await bed.orderedSession()
        return (bed, session)
    }

    private func booted(_ bed: Bed) async throws -> HubSession {
        let session = try bed.session()
        await session.waitForBoot()
        await session.outbox.drain()
        return session
    }

    /// The `transport_switch` controls queued in the session's outbox, not written yet.
    private func queuedRequests(_ session: HubSession) async throws -> [String] {
        try await session.store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT control_id FROM outbound_controls WHERE kind = 'transport_switch'")
        }
    }
}
