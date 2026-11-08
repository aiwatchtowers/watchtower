import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The term on a refused relay-only link (relay client Phase 5, Task 17, asks #1093, #1098, #1100), over the live `AppRoot`
/// and `Bed` with the account center on the bed's relay: the mark each answered read sets or clears, the two reads five
/// minutes apart, the foreground only, the end through today's unlink.
@MainActor
final class RelayTermWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString
    private let day: TimeInterval = 86_400

    @MainActor
    private struct Rig {
        let bed: Bed
        let session: HubSession
        let store: FakeSubscriptionStore
        /// The root's center now (a relaunch builds another).
        var center: RelayAccountCenter {
            get throws {
                let center = bed.root.env.relayAccount
                return try XCTUnwrap(center)
            }
        }
    }

    /// A relay-only link, the phone paying with the Mac in its slot, the account center wired.
    private func rig() async throws -> Rig {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        let store = FakeSubscriptionStore()
        bed.root.wireRelayAccount { store }
        return Rig(bed: bed, session: session, store: store)
    }

    /// A relaunch: the old center goes with the old root (a new process has one), then a new one is wired.
    private func relaunch(_ rig: Rig) async throws {
        rig.bed.root.env.relayAccount = nil
        try await rig.bed.relaunch(self)
        rig.bed.root.wireRelayAccount { rig.store }
    }

    private func entitlement(_ bed: Bed, _ state: String) async throws {
        let account = try await bed.fake.accountID(ofPhone: bed.phone.deviceID)
        try await bed.fake.setEntitlement(accountID: account, state: state, for: state == "active" ? .seconds(365 * 86_400) : .zero)
    }

    /// The relay refused this phone's subscription: the term starts now, on the root's clock. The relay's
    /// ENTITLEMENT_EXPIRED control is read by the center first, so no late read races the test.
    private func refused(_ rig: Rig) async throws -> RelayRefusedRecord {
        try await entitlement(rig.bed, "expired")
        let center = try rig.center
        try await poll({ center.phase == .free(ended: true) }, "the center read the expiry")
        await rig.session.lapseRelay()
        return try XCTUnwrap(try rig.bed.row()?.link.relayRefused)
    }

    /// The subscription is back and an answered read says so.
    private func renewed(_ rig: Rig) async throws {
        try await entitlement(rig.bed, "active")
        let center = try rig.center
        await center.refresh()
        try await poll({ (try? rig.bed.row()?.link.relayRefused) == nil }, "the paying read cleared the mark")
    }

    private func foreground(_ rig: Rig) async {
        await rig.bed.root.becameActive().value
    }

    /// Reads until one answers: the scripted failures left are used up.
    private func drainReadFaults(_ rig: Rig) async throws {
        let center = try rig.center
        for _ in 0 ..< 40 {
            await center.refresh()
            if center.phase != .unknown { return }
        }
    }

    private func termReadAt(_ rig: Rig) throws -> Date? {
        try rig.bed.row()?.link.relayRefused?.termReadAt
    }

    // MARK: - The mark, by the answered read

    /// Review M7: paying with the slot clears the mark, so the phone waits for keyboxes (parks) again.
    func testAnAnsweredSlotAllowsParkingAgain() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        XCTAssertFalse(rig.session.waitsForKeybox)
        try await renewed(rig)
        XCTAssertTrue(rig.session.waitsForKeybox, "the key source is back")
    }

    func testALapseEndStopsTheTerm() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        try await renewed(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row(), "nothing ends")
        XCTAssertNil(try rig.bed.row()?.link.relayRefused)
    }

    func testAnAnsweredSlotStopsTheTermOfASlotLoss() async throws {
        let rig = try await rig()
        await rig.session.relaySlotLost()
        XCTAssertEqual(try rig.bed.row()?.link.relayRefused?.cause, .slot)
        try await rig.center.refresh()
        XCTAssertNil(try rig.bed.row()?.link.relayRefused, "paying, the Mac in a slot")
    }

    /// Not paying, the Mac in a slot: still a lapse.
    func testAnAnsweredSlotDoesNotStopTheTermOfALapse() async throws {
        let rig = try await rig()
        let mark = try await refused(rig)
        try await rig.center.refresh()
        XCTAssertEqual(try rig.bed.row()?.link.relayRefused, mark)
    }

    func testASlotBackWithTheSubscriptionEndedKeepsTheTerm() async throws {
        let rig = try await rig()
        await rig.session.relaySlotLost()
        let mark = try XCTUnwrap(try rig.bed.row()?.link.relayRefused)
        try await entitlement(rig.bed, "expired")
        try await rig.center.refresh()
        // The relay's ENTITLEMENT_EXPIRED control runs its own read too: wait for the answered one.
        try await poll({ (try? rig.bed.row()?.link.relayRefused?.cause) == .lapse }, "the read set the cause")
        let now = try XCTUnwrap(try rig.bed.row()?.link.relayRefused)
        XCTAssertEqual(now.cause, .lapse)
        XCTAssertEqual(now.since, mark.since, "since stays")
    }

    func testAStoredKeyboxDoesNotStopTheTerm() async throws {
        let rig = try await rig()
        let mark = try await refused(rig)
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        await rig.bed.root.linking.reconcileKeyboxKeys(hubID: hubID, keybox: Keybox(grant: grant, keys: TestPhone.keyboxKeys(epoch: 2)))
        XCTAssertEqual(try rig.bed.row()?.link.relayRefused, mark, "no merge clears the mark")
        XCTAssertFalse(rig.session.waitsForKeybox)
    }

    // MARK: - Two reads, five minutes apart, in the foreground

    func testABackgroundLaunchDoesNotRunTheTerm() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await rig.bed.root.launch { [] }.value
        XCTAssertNotNil(try rig.bed.row(), "nothing ends")
        XCTAssertNil(try termReadAt(rig), "no read counts")
    }

    /// Also the person back past the date: the first opening shows the warning and ends nothing.
    func testOneAnsweredReadDoesNotEndTheLink() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(30 * day)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row())
        XCTAssertEqual(try termReadAt(rig), rig.bed.clock.now)
        let link = try XCTUnwrap(try rig.bed.row()?.link)
        XCTAssertEqual(
            RelayBannerModel.termLine(for: link, surface: .now, now: rig.bed.clock.now, heldPurchase: .none),
            "The link to Work Mac will end the next time this iPhone can confirm Relay still refuses it. "
                + "Its history and unsent actions on this iPhone will go.")
    }

    func testAPersonAwayPastTheDateSeesTheWarningFirst() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(60 * day)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row(), "the first opening ends nothing")
        XCTAssertNil(rig.bed.root.linking.notice)
    }

    func testTwoReadsWithinFiveMinutesDoNot() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        let first = try termReadAt(rig)
        rig.bed.clock.advance(299)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row())
        XCTAssertEqual(try termReadAt(rig), first, "the first read stays")
    }

    func testTwoReadsFiveMinutesApartEndTheLink() async throws {
        let rig = try await rig()
        try await rig.bed.sendTwoActions(rig.session)
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row(), "the row leaves Settings → Macs")
        XCTAssertNil(try rig.bed.keys.hubLink(hubID), "every key goes")
        XCTAssertNil(rig.bed.root.env.session(hubID))
        guard case .relayEnded(macName: "Work Mac", _) = rig.bed.root.linking.notice else {
            return XCTFail("S60: \(String(describing: rig.bed.root.linking.notice))")
        }
    }

    func testAFailedReadKeepsTheTermDue() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        rig.bed.fake.failNext("getAccountState", with: .unspecified, times: 20)
        for _ in 0 ..< 3 {
            rig.bed.clock.advance(7 * day)
            await foreground(rig)
        }
        XCTAssertNotNil(try rig.bed.row(), "weeks of failed reads erase nothing")
        XCTAssertNil(try termReadAt(rig))
        XCTAssertNotNil(try rig.bed.row()?.link.relayRefused, "the term stays due")
    }

    func testAFailedReadBetweenKeepsTheFirst() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        let first = try XCTUnwrap(try termReadAt(rig))
        rig.bed.clock.advance(600)
        rig.bed.fake.failNext("getAccountState", with: .unspecified, times: 20)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row())
        XCTAssertEqual(try termReadAt(rig), first)
        try await drainReadFaults(rig)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row(), "the first read still counts")
    }

    func testTheFirstReadSurvivesARestart() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        XCTAssertNotNil(try termReadAt(rig))
        try await relaunch(rig)
        rig.bed.clock.advance(300)
        await rig.bed.root.becameActive().value
        XCTAssertNil(try rig.bed.row(), "the second read, after the restart, ends it")
    }

    /// The first answer, right after a renewal send, was stale; the second, five minutes on, says paying.
    func testAStaleAnswerAfterTheRenewalSendIsCorrectedByTheSecond() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        XCTAssertNotNil(try termReadAt(rig))
        try await entitlement(rig.bed, "active")
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row(), "nothing ends")
        XCTAssertNil(try rig.bed.row()?.link.relayRefused, "the mark and its first read go")
    }

    func testRenewedWhileClosedKeepsTheLink() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        try await entitlement(rig.bed, "active")
        try await relaunch(rig)
        rig.bed.clock.advance(22 * day)
        await rig.bed.root.becameActive().value
        XCTAssertNotNil(try rig.bed.row())
        XCTAssertNil(try rig.bed.row()?.link.relayRefused, "the day-22 read clears the mark")
    }

    func testSlotBackWhileClosedKeepsTheLink() async throws {
        let rig = try await rig()
        await rig.session.relaySlotLost()
        try await relaunch(rig)
        rig.bed.clock.advance(22 * day)
        await rig.bed.root.becameActive().value
        XCTAssertNotNil(try rig.bed.row())
        XCTAssertNil(try rig.bed.row()?.link.relayRefused)
    }

    func testTheTermWaitsForARunningRecording() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await rig.session.recorder.recordVoiceNote()
        XCTAssertTrue(rig.session.recorder.isCapturing)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row(), "nothing ends during a recording")
        XCTAssertNil(try termReadAt(rig), "no read counts either")
    }

    /// Ask #1098: a moved Mac with the phone paying and in the slot has no term; refused, it ends as any other.
    func testATermPastDueOnAMovedMacEndsOnlyWhenRefused() async throws {
        let rig = try await rig()
        guard var link = try rig.bed.row()?.link else { return XCTFail("no row") }
        link.macMoved = 2
        XCTAssertTrue(rig.bed.root.persistRoute(link))
        rig.bed.clock.advance(60 * day)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNotNil(try rig.bed.row(), "no term: nothing refuses it")

        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row())
    }

    // MARK: - The end: today's unlink

    func testTheTermSendsTheFarewellAndRemovesTheSlot() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        let mac = rig.bed.mac.deviceID
        rig.bed.relayOps.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row())
        XCTAssertEqual(rig.bed.relayOps.count("removeSlot"), 1, "remove_slot sent once")
        XCTAssertTrue(rig.bed.root.pendingSlotRemovals().contains(mac), "the refused remove_slot is kept for launch")

        // At the next launch's foreground it goes again, and nothing holds it back.
        await foreground(rig)
        XCTAssertEqual(rig.bed.relayOps.count("removeSlot"), 2)
        XCTAssertFalse(rig.bed.root.pendingSlotRemovals().contains(mac))
    }

    func testForgetWorksWhenTheRelayRefusesTheFarewell() async throws {
        let rig = try await rig()
        await rig.session.relaySlotLost()
        rig.bed.relayOps.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        await rig.bed.root.linking.forget(hubID)
        XCTAssertNil(try rig.bed.row(), "the row and the local data go")
        XCTAssertNil(try rig.bed.keys.hubLink(hubID))
        XCTAssertTrue(rig.bed.root.pendingSlotRemovals().contains(rig.bed.mac.deviceID), "retried at launch")
        XCTAssertEqual(rig.bed.root.linking.phase, .idle, "it blocks nothing")
    }
}
