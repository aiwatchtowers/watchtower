import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// An iCloud link's upgrade to the relay (relay client Phase 3b Task 19): the live `AppRoot` over the follower's bed
/// (`Bed`: CloudKit in memory, the relay on `FakeHostedRelay`), a link that names no relay id for its Mac yet, an
/// ordered grant naming the Mac's relay identity, and the relay's account ops on `FakeRelayOps`. The phone is not a
/// reader of the Mac's data zone until a test lets it read (`allowReader`).
@MainActor
final class RelayUpgradeWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    // MARK: - The order

    func testUpgradeNamesTheRelayIDThenVouchesAddsTheSlotAndAsks() async throws {
        let (bed, session) = try await upgradeBed()
        try await allowReader(bed)
        bed.relayOps.park("vouch")

        let upgrade = Task { await session.upgradeToRelay() }
        try await waitUntil { bed.relayOps.isParked("vouch") }
        let named = try await deviceRecord(bed)
        XCTAssertEqual(named?.relayDeviceID, try proofID(), "the relay id is named before the vouch")
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .vouching)
        bed.relayOps.release("vouch")
        let outcome = await upgrade.value
        await session.outbox.drain()

        XCTAssertEqual(outcome, .underWay(.requested))
        XCTAssertEqual(bed.relayOps.ops, ["accountState", "vouch \(bed.mac.deviceID)", "addSlot \(bed.mac.deviceID)"])
        let asked = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(asked.map(\.target), ["relay"])
        let link = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(link.relayUpgrade?.step, .requested)
        XCTAssertEqual(link.relayUpgrade?.requestID, asked.first?.id)
        XCTAssertEqual(link.relayMacDeviceID, bed.mac.deviceID, "the Mac's relay identity is kept")
        XCTAssertEqual(link.relayAuthPub, WireBytes.base64URL(bed.macAuthPub))
        XCTAssertEqual(link.transport, .cloudKit, "the route stays on iCloud")
    }

    func testTheDeviceRecordCarriesAProvenRelayIDOnlyDuringAnUpgrade() async throws {
        let (bed, session) = try await upgradeBed()
        let device = try XCTUnwrap(session.linkedDevice)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            try encoded(bed.root.devicePayload(hubID: hubID, for: device, linkNonce: nil, unlinked: false, now: now)),
            try encoded(session.deviceSettings.devicePayload(for: device, linkNonce: nil, unlinked: false, now: now)),
            "no upgrade: today's record, byte for byte")

        _ = await session.upgradeToRelay()

        let payload = bed.root.devicePayload(hubID: hubID, for: device, linkNonce: nil, unlinked: false, now: now)
        XCTAssertEqual(payload.relayDeviceID, try proofID())
        XCTAssertTrue(RelayIDProof.verify(payload, hubID: TestE2E.hubID, deviceID: TestE2E.deviceID))
        XCTAssertFalse(RelayIDProof.verify(payload, hubID: UUID(), deviceID: TestE2E.deviceID), "bound to the hub")
        let sent = try await deviceRecord(bed)
        XCTAssertNotNil(sent)
        XCTAssertTrue(RelayIDProof.verify(try XCTUnwrap(sent), hubID: TestE2E.hubID, deviceID: TestE2E.deviceID))

        // An empty origin: even with an upgrade on the row, the record is today's.
        let (dark, darkSession) = try await upgradeBed(relayOff: true)
        try seed(dark, .vouching)
        let darkDevice = try XCTUnwrap(darkSession.linkedDevice)
        XCTAssertEqual(
            try encoded(dark.root.devicePayload(hubID: hubID, for: darkDevice, linkNonce: nil, unlinked: false, now: now)),
            try encoded(darkSession.deviceSettings.devicePayload(for: darkDevice, linkNonce: nil, unlinked: false, now: now)))
        XCTAssertEqual(dark.relayOps.proofs, 0)
    }

    /// The upgrade's record is rebuilt with the relay id: the switch stays in it.
    func testAnUpgradingRecordKeepsTheAlertSwitch() async throws {
        let (bed, session) = try await upgradeBed()
        let settings = session.deviceSettings
        let before = settings.workAlerts
        addTeardownBlock { @MainActor in settings.workAlerts = before }
        _ = await session.upgradeToRelay()
        settings.workAlerts = false
        let device = try XCTUnwrap(session.linkedDevice)
        let payload = bed.root.devicePayload(hubID: hubID, for: device, linkNonce: nil, unlinked: false, now: Date())
        XCTAssertNotNil(payload.relayDeviceID)
        XCTAssertTrue(payload.workAlertsOff)
    }

    // MARK: - The reader wait

    func testTheSwitchIsAskedOnlyAfterTheFirstDataZoneRead() async throws {
        let (bed, session) = try await upgradeBed()

        let outcome1 = await session.upgradeToRelay()
        XCTAssertNil(outcome1.refusal)
        bed.clock.advance(31)
        await bed.root.resumeRelayUpgrades()

        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
        let none = try await switchRequests(bed, session)
        XCTAssertTrue(none.isEmpty, "not asked while the data zone answers FORBIDDEN")
        let since = try bed.row()?.link.relayUpgrade?.slotSince

        // A relaunch resumes the wait.
        try await bed.relaunch(self)
        let relaunched = try await booted(bed)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.slotSince, since)

        try await allowReader(bed)
        await bed.root.resumeRelayUpgrades()

        let asked = try await switchRequests(bed, relaunched)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .requested)
        XCTAssertEqual(bed.relayOps.count("addSlot"), 1, "the slot was added once")
    }

    func testAwaitingReaderGivesUpAfterTheLimit() async throws {
        let (bed, session) = try await upgradeBed()
        let outcome2 = await session.upgradeToRelay()
        XCTAssertNil(outcome2.refusal)
        let since = try XCTUnwrap(try bed.row()?.link.relayUpgrade?.slotSince)

        bed.clock.advance(23 * 3600)
        try await bed.relaunch(self)
        _ = try await booted(bed)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
        XCTAssertNil(try bed.row()?.link.relayUpgrade?.refusal)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.slotSince, since, "the same clock")

        bed.clock.advance(3600)
        await bed.root.resumeRelayUpgrades()

        let upgrade = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
        XCTAssertEqual(upgrade.refusal, .readerNotConfirmed)
        XCTAssertEqual(
            upgrade.refusal?.message(macName: "Work Mac", now: bed.clock.now),
            "Work Mac didn't confirm Relay. Update Watchtower on the Mac and try again.")
        XCTAssertTrue(bed.relayOps.slots.contains(bed.mac.deviceID), "the slot is kept")
        XCTAssertEqual(bed.relayOps.count("removeSlot"), 0)
        let none = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(none.isEmpty)

        // Asked again: the slot is reused, no vouch, no add_slot, a new 24 h wait.
        let session2 = try bed.session()
        let opsBefore = bed.relayOps.ops.count
        let outcome3 = await session2.upgradeToRelay()
        XCTAssertNil(outcome3.refusal)
        XCTAssertEqual(Array(bed.relayOps.ops.dropFirst(opsBefore)), ["accountState"])
        let again = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
        XCTAssertEqual(again.step, .awaitingReader)
        XCTAssertNil(again.refusal)
        XCTAssertEqual(again.slotSince, bed.clock.now)
    }

    // MARK: - The checks

    func testAnUnknownAccountStateIsANoOpAndRetried() async throws {
        let (bed, session) = try await upgradeBed()
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.unreachable)

        let outcome4 = await session.upgradeToRelay()
        XCTAssertEqual(outcome4, .waiting)

        XCTAssertNil(try bed.row()?.link.relayUpgrade, "nothing written")
        let unnamed = try await deviceRecord(bed)
        XCTAssertNil(unnamed?.relayDeviceID)
        XCTAssertEqual(bed.relayOps.ops, ["accountState"])

        // A resume at a later step: the read fails again, the step stays.
        try seed(bed, .vouching)
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.attestationBackoff(until: Date()))
        let outcome5 = await session.upgradeToRelay()
        XCTAssertNil(outcome5.refusal)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .vouching)
        XCTAssertNil(try bed.row()?.link.relayUpgrade?.refusal)

        // The next pass reads `.yes` and goes on.
        let outcome6 = await session.upgradeToRelay()
        XCTAssertNil(outcome6.refusal)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
    }

    /// The retry of a first start that decided nothing comes from the resumer, not from a second call.
    func testAnUnknownFirstStartIsRetriedByTheResumer() async throws {
        let (bed, session) = try await upgradeBed()
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.unreachable)

        let outcome = await session.upgradeToRelay()

        XCTAssertEqual(outcome, .waiting)
        XCTAssertNil(try bed.row()?.link.relayUpgrade)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
        XCTAssertEqual(bed.relayOps.count("accountState"), 2)
    }

    func testAGrantWithoutACoherentRelayIdentityCannotUpgrade() async throws {
        let (bed, session) = try await upgradeBed(macRelay: false)
        let outcome7 = await session.upgradeToRelay()
        XCTAssertEqual(outcome7.refusal, .noRelayIdentity)

        // The Mac's id with another key: not coherent.
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        try await publishGrant(bed, relayDeviceID: bed.mac.deviceID, relayAuthPub: WireBytes.base64URL(other))
        await bed.fetch(session)
        let outcome8 = await session.upgradeToRelay()
        XCTAssertEqual(outcome8.refusal, .noRelayIdentity)

        XCTAssertTrue(bed.relayOps.ops.isEmpty)
        XCTAssertNil(try bed.row()?.link.relayUpgrade)
        let record = try await deviceRecord(bed)
        XCTAssertNil(record)
    }

    func testAnEmptyOriginCannotUpgrade() async throws {
        let (bed, session) = try await upgradeBed(relayOff: true)

        let outcome9 = await session.upgradeToRelay()
        XCTAssertEqual(outcome9.refusal, .relayOff)

        XCTAssertFalse(bed.rootRelay.isBuilt, "no relay session, so no Keychain item and no register")
        XCTAssertTrue(bed.relayOps.ops.isEmpty)
        XCTAssertEqual(bed.relayOps.proofs, 0)
        XCTAssertNil(try bed.row()?.link.relayUpgrade)
        let record = try await deviceRecord(bed)
        XCTAssertNil(record, "no device-record change")
    }

    func testALegacyPathHubIsNeverAsked() async throws {
        let (bed, session) = try await upgradeBed(ordered: false)

        let outcome10 = await session.upgradeToRelay()
        XCTAssertEqual(outcome10.refusal, .notSupported)

        XCTAssertTrue(bed.relayOps.ops.isEmpty)
        XCTAssertNil(try bed.row()?.link.relayUpgrade)
        let record = try await deviceRecord(bed)
        XCTAssertNil(record)
        let none = try await bed.cloudControls(.transportSwitch)
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Vouch and add_slot

    func testVouchRefusalsEndTheUpgradeWithTheirReason() async throws {
        let (bed, session) = try await upgradeBed()
        for refusal: HostedRelayPairing.VouchRefusal in [.notPaying, .updateRequired, .hubNotOnRelay, .slotsFull, .notConfirmed] {
            bed.relayOps.fail("vouch", with: refusal)
            let outcome11 = await session.upgradeToRelay()
            XCTAssertEqual(outcome11.refusal, .vouch(refusal))
            let upgrade = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
            XCTAssertEqual(upgrade.refusal, .vouch(refusal))
            XCTAssertFalse(upgrade.holdsSlot)
        }
        XCTAssertEqual(bed.relayOps.count("addSlot"), 0)

        // A transient answer is no refusal: the step waits for the next pass.
        bed.relayOps.fail("vouch", with: HostedRelayPairing.VouchRefusal.unreachable)
        let outcome12 = await session.upgradeToRelay()
        XCTAssertNil(outcome12.refusal)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .vouching)
        XCTAssertNil(try bed.row()?.link.relayUpgrade?.refusal)
    }

    func testHubNotVouchedOnAddSlotVouchesAgainOnce() async throws {
        let (bed, session) = try await upgradeBed()
        let notVouched = HostedRelayError.server(code: .hubNotVouched, retryAfter: nil)
        let mac = bed.mac.deviceID
        bed.relayOps.fail("addSlot", with: notVouched, notVouched)

        let outcome13 = await session.upgradeToRelay()
        XCTAssertEqual(outcome13.refusal, .vouch(.notConfirmed), "a second HUB_NOT_VOUCHED ends it")
        XCTAssertEqual(bed.relayOps.ops, ["accountState", "vouch \(mac)", "addSlot \(mac)", "vouch \(mac)", "addSlot \(mac)"])

        bed.relayOps.fail("addSlot", with: notVouched)
        let before = bed.relayOps.ops.count
        let outcome14 = await session.upgradeToRelay()
        XCTAssertNil(outcome14.refusal)
        XCTAssertEqual(
            Array(bed.relayOps.ops.dropFirst(before)),
            ["accountState", "vouch \(mac)", "addSlot \(mac)", "vouch \(mac)", "addSlot \(mac)"])
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
    }

    // MARK: - A relaunch

    func testARelaunchResumesAtNamingTheRelayID() async throws {
        let bed = try await relaunched(at: .namingRelayID)
        await bed.root.resumeRelayUpgrades()
        let named = try await deviceRecord(bed)
        XCTAssertEqual(named?.relayDeviceID, try proofID())
        XCTAssertEqual(bed.relayOps.ops, ["accountState", "vouch \(bed.mac.deviceID)", "addSlot \(bed.mac.deviceID)"])
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
    }

    func testARelaunchResumesAtVouching() async throws {
        let bed = try await relaunched(at: .vouching)
        await bed.root.resumeRelayUpgrades()
        let record = try await deviceRecord(bed)
        XCTAssertNil(record, "the device record is not written again")
        XCTAssertEqual(bed.relayOps.ops, ["accountState", "vouch \(bed.mac.deviceID)", "addSlot \(bed.mac.deviceID)"])
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
    }

    func testARelaunchResumesAtAddingTheSlot() async throws {
        let bed = try await relaunched(at: .addingSlot)
        await bed.root.resumeRelayUpgrades()
        let record = try await deviceRecord(bed)
        XCTAssertNil(record)
        XCTAssertEqual(
            bed.relayOps.ops, ["accountState", "vouch \(bed.mac.deviceID)", "addSlot \(bed.mac.deviceID)"],
            "the vouch again (it lasts 10 minutes), then add_slot")
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .awaitingReader)
    }

    func testARelaunchResumesAtAwaitingReader() async throws {
        let (bed, session) = try await upgradeBed()
        let outcome15 = await session.upgradeToRelay()
        XCTAssertNil(outcome15.refusal)
        let ops = bed.relayOps.ops
        try await bed.relaunch(self)
        let relaunched = try await booted(bed)
        try await allowReader(bed)

        await bed.root.resumeRelayUpgrades()

        XCTAssertEqual(bed.relayOps.ops, ops, "no account read, vouch or add_slot again")
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .requested)
        let asked = try await switchRequests(bed, relaunched)
        XCTAssertEqual(asked.count, 1)
    }

    func testARelaunchResumesAtRequested() async throws {
        let (bed, session) = try await requestedBed()
        let ops = bed.relayOps.ops
        try await bed.relaunch(self)
        let relaunched = try await booted(bed)

        await bed.root.resumeRelayUpgrades()

        XCTAssertEqual(bed.relayOps.ops, ops)
        let asked = try await switchRequests(bed, relaunched)
        XCTAssertEqual(asked.count, 1, "not asked again")
        _ = session
        try await bed.writeRejection(RelayUpgrade.notPaying, on: .cloudKit)
        await fetch(bed, relaunched)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .notPaying, "the answer still reaches the upgrade")
    }

    // MARK: - The request and its answers

    func testTheRequestGoesToBothMailboxesWithOneID() async throws {
        let (bed, session) = try await requestedBed()

        let onCloud = try await bed.cloudControls(.transportSwitch)
        let onRelay = try await bed.relayControls(.transportSwitch)

        XCTAssertEqual(onCloud.count, 1)
        XCTAssertEqual(onCloud.map(\.id), onRelay.map(\.id))
        XCTAssertEqual(onRelay.map(\.target), ["relay"])
        XCTAssertEqual(onRelay.first?.deviceID, TestE2E.deviceID.uuidString)
        XCTAssertEqual(onRelay.first?.hubID, hubID)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.requestID, onCloud.first?.id)
        _ = session
    }

    func testTheInitiatorStaysOnICloudUntilSwitched() async throws {
        let (bed, session) = try await requestedBed()

        await fetch(bed, session)
        bed.clock.advance(31)
        await fetch(bed, session)

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertTrue(bed.root.env.session(hubID) === session)
        XCTAssertEqual(session.route, .cloudKit(.private))
        XCTAssertNil(bed.root.routeMoves[hubID])

        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let moved = try await bed.fetchAndFollow(session)

        XCTAssertEqual(moved.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .switched)
    }

    func testSwitchedEndsTheUpgrade() async throws {
        let (bed, session) = try await requestedBed()

        // The hub read the relay copy first and answered there: the upgrade's pass reads it.
        try await bed.writeSwitch(target: .relay, epoch: 2, on: .relay)
        bed.clock.advance(31)
        await bed.root.resumeRelayUpgrades()
        await bed.root.routeMoves[hubID]?.value

        let link = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(link.transport, .relay)
        XCTAssertEqual(link.relayUpgrade?.step, .switched)
        XCTAssertFalse(bed.root.env.session(hubID) === session)
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), [1, 2])
        // Nothing left to resume.
        let opsBefore = bed.relayOps.ops
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(bed.relayOps.ops, opsBefore)
    }

    /// The hub already runs on the relay (a lapse moved this phone back to iCloud in the same epoch): its answer names
    /// the relay in the epoch the phone has, and the waiting upgrade follows it.
    func testAnAnswerForTheTransportItIsOnEndsTheUpgrade() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeSwitch(target: .relay, epoch: 1, on: .cloudKit)
        let moved = try await bed.fetchAndFollow(session)

        XCTAssertEqual(moved.route, .hostedRelay(macDeviceID: bed.mac.deviceID))
        let link = try XCTUnwrap(bed.row()?.link)
        XCTAssertEqual(link.transport, .relay)
        XCTAssertEqual(link.relayUpgrade?.step, .switched)
        XCTAssertTrue(try Bed.handled(moved, bed.switchID))
    }

    /// A same-epoch answer naming iCloud is no switch: it is read, and the upgrade keeps waiting.
    func testASameEpochCloudKitAnswerIsNotASwitch() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeSwitch(target: .cloudKit, epoch: 1, on: .cloudKit)
        await fetch(bed, session)

        XCTAssertTrue(try Bed.handled(session, bed.switchID))
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .requested)
        XCTAssertNil(try bed.row()?.link.relayUpgrade?.refusal)
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
    }

    /// A finished upgrade whose hub went back to iCloud runs again from the device record; the slot is reused.
    func testAFinishedUpgradeRunsAgainAfterAMoveBack() async throws {
        let (bed, session) = try await requestedBed()
        let firstRequest = try XCTUnwrap(try bed.row()?.link.relayUpgrade?.requestID)
        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let onRelay = try await bed.fetchAndFollow(session)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .switched)
        try await bed.writeSwitch(target: .cloudKit, epoch: 3, on: .relay)
        let back = try await bed.fetchAndFollow(onRelay)
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)

        let outcome = await back.upgradeToRelay()

        XCTAssertEqual(outcome, .underWay(.requested))
        let upgrade = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
        XCTAssertNotEqual(upgrade.requestID, firstRequest)
        XCTAssertEqual(bed.relayOps.count("vouch"), 1, "the slot is reused")
        XCTAssertEqual(bed.relayOps.count("addSlot"), 1)
    }

    /// The row names the request before it is queued: a queue step that fails leaves `.requested` with the id and
    /// `askQueued` false, and the next pass queues that same id; an answer read at once still ends the upgrade.
    func testTheRowAwaitsTheAnswerBeforeTheRequestCanLeave() async throws {
        let (bed, session) = try await upgradeBed()
        try await allowReader(bed)
        let upgrader = try XCTUnwrap(session.relayUpgrader)
        let queue = upgrader.queue
        upgrader.queue = { _, _ in throw QueueFault() }

        let outcome = await session.upgradeToRelay()

        XCTAssertEqual(outcome, .underWay(.requested))
        let named = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
        XCTAssertFalse(named.askQueued)
        let id = try XCTUnwrap(named.requestID)
        let none = try await queuedRequests(session)
        XCTAssertTrue(none.isEmpty)

        upgrader.queue = queue
        await session.outbox.holdFlushes()
        bed.clock.advance(31)
        await bed.root.resumeRelayUpgrades()

        let queued = try await queuedRequests(session)
        XCTAssertEqual(queued, [id], "the same id")
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.askQueued, true)
        try await bed.writeRejection(RelayUpgrade.notPaying, on: .cloudKit)
        await fetch(bed, session)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .notPaying)
        await session.outbox.releaseFlushes()
    }

    /// A restart after a refusal that decides nothing (the account read fails) is `.waiting`, not the old refusal, and
    /// the resumer runs it once the relay answers.
    func testARestartAfterARefusalThatDecidesNothingWaits() async throws {
        let (bed, session) = try await requestedBed()
        try await bed.writeRejection(RelayUpgrade.notPaying, on: .cloudKit)
        await fetch(bed, session)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .notPaying)
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.unreachable)

        let outcome = await session.upgradeToRelay()

        XCTAssertEqual(outcome, .waiting)
        bed.clock.advance(31)
        await bed.root.resumeRelayUpgrades()
        let upgrade = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
        XCTAssertNil(upgrade.refusal)
        XCTAssertEqual(upgrade.step, .requested)
    }

    /// The same after a switch the hub has gone back from: `.waiting`, not `.switched`.
    func testARestartAfterASwitchThatDecidesNothingWaits() async throws {
        let (bed, session) = try await requestedBed()
        try await bed.writeSwitch(target: .relay, epoch: 2, on: .cloudKit)
        let onRelay = try await bed.fetchAndFollow(session)
        try await bed.writeSwitch(target: .cloudKit, epoch: 3, on: .relay)
        let back = try await bed.fetchAndFollow(onRelay)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .switched)
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.unreachable)

        let outcome = await back.upgradeToRelay()

        XCTAssertEqual(outcome, .waiting)
        bed.clock.advance(31)
        await bed.root.resumeRelayUpgrades()
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .requested)
    }

    func testTooSoonKeepsRetryAt() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeRejection(RelayUpgrade.tooSoon, retryAfter: 240, on: .cloudKit)
        await fetch(bed, session)

        let retryAt = bed.clock.now.addingTimeInterval(240)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .tooSoon(retryAt: retryAt))
        XCTAssertEqual(
            RelayUpgradeRefusal.tooSoon(retryAt: retryAt).message(macName: "Work Mac", now: bed.clock.now),
            "Switching to Relay is possible again in 4 min")
        bed.clock.advance(300)
        await bed.root.resumeRelayUpgrades()
        let asked = try await switchRequests(bed, session)
        XCTAssertEqual(asked.count, 1, "nothing is retried by itself")
    }

    func testNotPayingEndsTheUpgrade() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeRejection(RelayUpgrade.notPaying, on: .cloudKit)
        await fetch(bed, session)

        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .notPaying)
        XCTAssertTrue(bed.relayOps.slots.contains(bed.mac.deviceID), "the slot is kept")
        XCTAssertEqual(bed.relayOps.count("removeSlot"), 0)
    }

    func testUnavailableAsksAgainOnceAfterRetryAfter() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeRejection(RelayUpgrade.unavailable, retryAfter: 60, on: .cloudKit)
        await fetch(bed, session)
        XCTAssertNil(try bed.row()?.link.relayUpgrade?.refusal)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.retryAt, bed.clock.now.addingTimeInterval(60))

        bed.clock.advance(30)
        await bed.root.resumeRelayUpgrades()
        let early = try await switchRequests(bed, session)
        XCTAssertEqual(early.count, 1, "not before retry_after_s")

        bed.clock.advance(30)
        await bed.root.resumeRelayUpgrades()
        let again = try await switchRequests(bed, session)
        XCTAssertEqual(again.count, 2, "asked once more")
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.requestID, again.last?.id)

        try await bed.writeRejection(RelayUpgrade.unavailable, retryAfter: 60, on: .cloudKit)
        await fetch(bed, session)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .unavailable)
        bed.clock.advance(120)
        await bed.root.resumeRelayUpgrades()
        let after = try await switchRequests(bed, session)
        XCTAssertEqual(after.count, 2, "only one automatic new request")
    }

    func testAnUnknownReasonIsReadAsUnavailable() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeRejection("reason_from_a_newer_hub", retryAfter: 60, on: .cloudKit)
        await fetch(bed, session)
        XCTAssertNil(try bed.row()?.link.relayUpgrade?.refusal)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.retryAt, bed.clock.now.addingTimeInterval(60),
                       "one automatic new request, not left at .requested")

        bed.clock.advance(60)
        await bed.root.resumeRelayUpgrades()
        let again = try await switchRequests(bed, session)
        XCTAssertEqual(again.count, 2, "asked once more")

        try await bed.writeRejection("reason_from_a_newer_hub", retryAfter: 60, on: .cloudKit)
        await fetch(bed, session)
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .unavailable)
        XCTAssertEqual(
            RelayUpgradeRefusal.unavailable.message(macName: "Work Mac", now: bed.clock.now),
            "Work Mac couldn't switch right now. Try again in a minute.")
    }

    func testNotSupportedEndsTheUpgrade() async throws {
        let (bed, session) = try await requestedBed()

        try await bed.writeRejection(RelayUpgrade.notSupported, on: .cloudKit)
        await fetch(bed, session)

        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .notSupported)
        XCTAssertEqual(
            RelayUpgradeRefusal.notSupported.message(macName: "Work Mac", now: bed.clock.now),
            "Work Mac can't switch to Relay. Update Watchtower on the Mac.")
    }

    func testARejectionCopyOnTheOtherTransportIsDeletedUnread() async throws {
        let (bed, session) = try await requestedBed()
        let rejection = try await bed.writeRejection(RelayUpgrade.unavailable, retryAfter: 60, on: .cloudKit)
        try await bed.writeControl(rejection, on: .relay)

        await fetch(bed, session)
        XCTAssertTrue(try Bed.handled(session, rejection.id))
        bed.clock.advance(31)
        await bed.root.resumeRelayUpgrades()

        let upgrade = try XCTUnwrap(try bed.row()?.link.relayUpgrade)
        XCTAssertNil(upgrade.refusal, "the copy is not a second unavailable")
        XCTAssertFalse(upgrade.askedAgain)
        let onRelay = try await bed.relayMailbox().map(\.name)
        let wire = try TestPhone.transport().wireName(plain: rejection.recordName, zone: .relay)
        XCTAssertFalse(onRelay.contains(wire), "deleted unread")
    }

    // MARK: - Unlink

    func testUnlinkingAnUpgradingICloudLinkFreesItsSlot() async throws {
        let (bed, session) = try await upgradeBed()
        let outcome16 = await session.upgradeToRelay()
        XCTAssertNil(outcome16.refusal)
        let mac = bed.mac.deviceID
        XCTAssertTrue(bed.relayOps.slots.contains(mac))
        bed.relayOps.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)

        await bed.root.linking.unlink(hubID)

        XCTAssertEqual(bed.relayOps.count("removeSlot"), 1)
        XCTAssertNil(try bed.row())
        let farewell = try await deviceRecord(bed)
        XCTAssertEqual(farewell?.unlinked, true, "the farewell first, over iCloud")
        XCTAssertEqual(try bed.registry.pendingSlotRemovals(), [mac], "kept for a retry at launch")

        await bed.root.becameActive().value

        XCTAssertEqual(bed.relayOps.count("removeSlot"), 2)
        XCTAssertFalse(bed.relayOps.slots.contains(mac))
        XCTAssertEqual(try bed.registry.pendingSlotRemovals(), [])

        // An unlink before `add_slot` calls no relay op.
        let (early, earlySession) = try await upgradeBed()
        early.relayOps.fail("vouch", with: HostedRelayPairing.VouchRefusal.hubNotOnRelay)
        let outcome17 = await earlySession.upgradeToRelay()
        XCTAssertEqual(outcome17.refusal, .vouch(.hubNotOnRelay))
        let ops = early.relayOps.ops
        await early.root.linking.unlink(hubID)
        XCTAssertNil(try early.row())
        XCTAssertEqual(early.relayOps.ops, ops)
    }

    /// A kill after `add_slot` and before its step was saved leaves `.addingSlot` with no `slotSince`: an unlink still
    /// frees whatever slot the relay may hold for the Mac (`NOT_FOUND` counts as freed).
    func testUnlinkingAtAddingTheSlotFreesItsSlot() async throws {
        let (bed, _) = try await upgradeBed()
        let mac = bed.mac.deviceID
        try seed(bed, .addingSlot, mac: mac)
        bed.relayOps.slots = [mac]

        await bed.root.linking.unlink(hubID)

        XCTAssertNil(try bed.row())
        XCTAssertEqual(bed.relayOps.ops, ["removeSlot \(mac)"])
        XCTAssertTrue(bed.relayOps.slots.isEmpty)
        XCTAssertEqual(try bed.registry.pendingSlotRemovals(), [])
    }

    // MARK: - Helpers

    /// The bed: an iCloud link naming no relay id for its Mac, its booted session on the ordered path (or not), the
    /// grant naming the Mac's relay identity (or not), the phone no reader of the Mac's data zone yet.
    private func upgradeBed(
        ordered: Bool = true, macRelay: Bool = true, relayOff: Bool = false
    ) async throws -> (Bed, HubSession) {
        let bed = try await Bed.make(self, on: .cloudKit, macRelayID: false, relayOff: relayOff)
        try await bed.fake.pair(mac: bed.mac.deviceID, phones: [])
        let session = try bed.session()
        await session.waitForBoot()
        try await bed.publishGrant(ordered: ordered, macRelay: macRelay)
        await fetch(bed, session)
        await session.epochAckWork?.value
        await session.outbox.drain()
        let onOrderedPath = try await session.outbox.orderedActions()
        XCTAssertEqual(onOrderedPath, ordered)
        return (bed, session)
    }

    /// An upgrade that asked for the switch (the phone a reader).
    private func requestedBed() async throws -> (Bed, HubSession) {
        let (bed, session) = try await upgradeBed()
        try await allowReader(bed)
        let outcome19 = await session.upgradeToRelay()
        XCTAssertNil(outcome19.refusal)
        await session.outbox.drain()
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .requested)
        return (bed, session)
    }

    /// A bed whose row holds an upgrade at `step` (as a kill there leaves it), relaunched.
    private func relaunched(at step: RelayUpgradeStep) async throws -> Bed {
        let (bed, _) = try await upgradeBed()
        try seed(bed, step)
        try await bed.relaunch(self)
        _ = try await booted(bed)
        return bed
    }

    private func seed(_ bed: Bed, _ step: RelayUpgradeStep, mac: String? = nil) throws {
        var link = try XCTUnwrap(bed.row()?.link)
        link.relayUpgrade = RelayUpgradeRecord(step: step, macDeviceID: mac)
        XCTAssertTrue(try bed.registry.updateLink(link))
    }

    /// The relaunched root's session, booted.
    private func booted(_ bed: Bed) async throws -> HubSession {
        let session = try bed.session()
        await session.waitForBoot()
        await session.outbox.drain()
        return session
    }

    /// The Mac names the phone a reader of its data zone (its `set_hub_readers`).
    private func allowReader(_ bed: Bed) async throws {
        try await bed.fake.pair(mac: bed.mac.deviceID, phones: [bed.phone.deviceID])
    }

    /// One fetch, then the passes it started.
    private func fetch(_ bed: Bed, _ session: HubSession) async {
        await bed.fetch(session)
        await session.relayUpgrader?.idle()
        await session.outbox.drain()
    }

    /// The `transport_switch` controls in the session's outbox queue, not written yet.
    private func queuedRequests(_ session: HubSession) async throws -> [String] {
        try await session.store.reader.read { db in
            try String.fetchAll(db, sql: "SELECT control_id FROM outbound_controls WHERE kind = 'transport_switch'")
        }
    }

    /// Every `transport_switch` the phone wrote on iCloud, after the outbox's flush.
    private func switchRequests(_ bed: Bed, _ session: HubSession) async throws -> [ControlPayload] {
        await session.outbox.drain()
        return try await bed.cloudControls(.transportSwitch)
    }

    /// The phone's `device` record on iCloud, opened; nil when none was written.
    private func deviceRecord(_ bed: Bed) async throws -> DevicePayload? {
        let opened = try await TestPhone.transport(over: bed.cloud.inner).changes(in: .relay, since: nil).changed
        return try opened.last { $0.kind == RelayRecordKind.device.rawValue }
            .map { try RelayCoder.makeDecoder().decode(DevicePayload.self, from: $0.payload) }
    }

    /// The relay id `FakeRelayOps` signs for.
    private func proofID() throws -> String {
        RelayIDs.deviceID(publicKey: FakeRelayOps.relayKey.publicKey.rawRepresentation)
    }

    private func encoded(_ payload: DevicePayload) throws -> Data {
        try RelayCoder.makeEncoder().encode(payload)
    }

    /// This phone's ordered grant with the given relay pair.
    private func publishGrant(_ bed: Bed, relayDeviceID: String, relayAuthPub: String) async throws {
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, mayStartSessions: true, orderedActions: 1,
            transports: ["cloudkit", "relay"], relayDeviceID: relayDeviceID, relayAuthPub: relayAuthPub)
        try await TestPhone.hub(over: bed.cloud.inner).save([try TestPhone.grantRecord(grant, modifiedAt: Date())])
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw WaitTimedOut() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A wait in a test that never ended.
private struct WaitTimedOut: Error {}

/// The queue step's failure in a test.
private struct QueueFault: Error {}

@MainActor
extension Bed {
    /// The hub's `transport_switch_rejected{reason, retry_after_s}` for this phone on `route`.
    @discardableResult
    func writeRejection(_ reason: String, retryAfter: UInt32? = nil, on route: TransportKind) async throws -> ControlPayload {
        let control = ControlPayload(
            id: UUID().uuidString, kind: .transportSwitchRejected, deviceID: TestE2E.deviceID.uuidString, hubID: hubID,
            reason: reason, retryAfterS: retryAfter)
        try await writeControl(control, on: route)
        return control
    }
}
