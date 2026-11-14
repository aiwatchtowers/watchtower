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
    private func rig(
        farewellLive: Bool = false, secondRelayHub: String? = nil, relayHTTP: ((any RelayHTTP) -> any RelayHTTP)? = nil
    ) async throws -> Rig {
        let bed = try await Bed.make(
            self, on: .relay, hubTransports: ["relay"], relayHTTP: relayHTTP, farewellLive: farewellLive,
            secondRelayHub: secondRelayHub)
        let session = try await bed.orderedSession()
        let store = FakeSubscriptionStore()
        bed.root.wireRelayAccount { store }
        bed.root.env.setActive(true) // the scene is in the foreground (review M2)
        let rig = Rig(bed: bed, session: session, store: store)
        // The socket's `.reachable(true)` is the center's first event, and its pass reads the account in the background:
        // a test that writes the link or changes the entitlement before that pass ended races its answer (#1771).
        try await handled(rig, after: 0)
        return rig
    }

    /// Waits until the center's event loop finished handling the events after the first `count`, with everything each
    /// one started and awaited (its read, its apply, the lapses): the counter moves only once a handling returned. The
    /// lapse ends a paying answer starts unawaited (`endLapses`) are waited for too.
    private func handled(_ rig: Rig, after count: Int) async throws {
        let center = try rig.center
        try await poll({ center.handledEvents > count }, "the center handled the relay's event")
        await center.lapseEndsFinished()
    }

    /// A relaunch: the old center goes with the old root (a new process has one), then a new one is wired.
    private func relaunch(_ rig: Rig) async throws {
        rig.bed.root.env.relayAccount = nil
        try await rig.bed.relaunch(self)
        rig.bed.root.wireRelayAccount { rig.store }
        rig.bed.root.env.setActive(true)
    }

    private func entitlement(_ bed: Bed, _ state: String) async throws {
        let account = try await bed.fake.accountID(ofPhone: bed.phone.deviceID)
        try await bed.fake.setEntitlement(accountID: account, state: state, for: state == "active" ? .seconds(365 * 86_400) : .zero)
    }

    /// The relay refused this phone's subscription: the term starts now, on the root's clock. The relay's
    /// ENTITLEMENT_EXPIRED control is handled by the center to its end first (its read, its apply and the lapse it
    /// starts), so no late read or lapse races the test. A wait on the phase alone returned in the middle of `apply`,
    /// with that lapse still to run (#1771).
    private func refused(_ rig: Rig) async throws -> RelayRefusedRecord {
        let before = try rig.center.handledEvents
        try await entitlement(rig.bed, "expired")
        try await handled(rig, after: before)
        XCTAssertEqual(try rig.center.phase, .free(ended: true), "the center read the expiry")
        await rig.session.lapseRelay()
        return try XCTUnwrap(try rig.bed.row()?.link.relayRefused)
    }

    /// The subscription is back and an answered read says so; the lapse ends it started have run.
    private func renewed(_ rig: Rig) async throws {
        try await entitlement(rig.bed, "active")
        let center = try rig.center
        await center.refresh()
        await center.lapseEndsFinished()
        XCTAssertNil(try rig.bed.row()?.link.relayRefused, "the paying read cleared the mark")
    }

    /// The app comes to the foreground: the root's work, the center's pass it started (`foreground()` runs it
    /// unawaited), then the lapse ends that pass started.
    private func foreground(_ rig: Rig) async {
        let center = rig.bed.root.env.relayAccount
        let work = rig.bed.root.becameActive()
        let pass = center?.passTask
        await work.value
        await pass?.value
        await center?.lapseEndsFinished()
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
        let before = try rig.center.handledEvents
        try await entitlement(rig.bed, "expired")
        // The relay's ENTITLEMENT_EXPIRED control runs its own read: its handling ends before the test's read.
        try await handled(rig, after: before)
        try await rig.center.refresh()
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
        // The refusal withdrew both and listed them Not delivered: nothing is still waiting, so "Not sent" is 0, and
        // the Not delivered rows go with the link.
        XCTAssertEqual(try Bed.rows(rig.session, .undelivered).count, 2)
        XCTAssertEqual(AppRoot.pendingActionCount(rig.session), 0)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row(), "the row leaves Settings → Macs")
        XCTAssertNil(try rig.bed.keys.hubLink(hubID), "every key goes")
        XCTAssertNil(rig.bed.root.env.session(hubID))
        XCTAssertEqual(rig.bed.root.linking.notice, .relayEnded(macName: "Work Mac", notSent: 0), "S60, with today's Not sent count")
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

    // MARK: - Fix round 1

    /// Review I1: the read turns the `.slot` mark into `.lapse` (it shows the subscription ended) while this phone's own
    /// purchase is held: the hold follows the fresh cause (ask #1100), so nothing ends and the first read stays.
    func testAHeldPurchaseHoldsATermWhoseReadTurnsTheSlotIntoALapse() async throws {
        let rig = try await rig()
        let first = try rig.center
        try await poll({ first.phase == .paying(grace: false, macs: [rig.bed.mac.deviceID]) }, "the first read")
        try await entitlement(rig.bed, "expired")
        try await poll({ first.phase == .free(ended: true) }, "the center read the expiry")
        // This phone's own purchase, not a renewal, current in StoreKit; the claim moved away, so only a press sends it.
        let accountID = try await rig.bed.fake.accountID(ofPhone: rig.bed.phone.deviceID)
        let token = try XCTUnwrap(UUID(uuidString: accountID))
        rig.store.unfinishedResult = [RelayTransaction(
            id: 7, originalID: 1000, appAccountToken: token,
            jws: FakeHostedRelay.fakeJWS(originalTransactionID: "1000", appAccountToken: token.uuidString, signedDate: Date()),
            revoked: false, isRenewal: false, expiresAt: Date().addingTimeInterval(30 * day))]
        rig.bed.defaults.set(false, forKey: RelayAccountCenter.holdsSubscriptionKey)
        rig.bed.root.env.relayAccount = nil
        rig.bed.root.wireRelayAccount { rig.store }
        let center = try rig.center
        // The new center's first pass answers now, so the foreground below makes no pass of its own (one a minute) and
        // the term's own read is the one that turns the mark.
        await center.foreground()?.value
        try await poll({ center.phase == .free(ended: true) && center.termHold == .held }, "the new center read and holds")
        // The link lost its slot while paying (`.slot`) and had its first term read ten minutes ago.
        let now = rig.bed.clock.now
        guard var link = try rig.bed.row()?.link else { return XCTFail("no row") }
        let firstRead = now.addingTimeInterval(-600)
        link.relayRefused = RelayRefusedRecord(since: now.addingTimeInterval(-22 * day), cause: .slot, termReadAt: firstRead)
        XCTAssertTrue(rig.bed.root.persistRoute(link))

        await foreground(rig)

        XCTAssertNotNil(try rig.bed.row(), "held: nothing ends")
        XCTAssertEqual(try rig.bed.row()?.link.relayRefused?.cause, .lapse, "the term's read set the cause")
        XCTAssertEqual(try termReadAt(rig), firstRead, "the first read is unchanged")
        XCTAssertFalse(rig.bed.fake.log.map(FakeHostedRelay.name).contains("submitTransaction"), "nothing sent: only a press")
    }

    /// Review M2: a term found due after the person left the app waits for the next foreground.
    func testATermDueAfterThePersonLeftWaits() async throws {
        let rig = try await rig()
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        let first = try termReadAt(rig)
        rig.bed.clock.advance(300)
        rig.bed.root.env.setActive(false)
        await rig.bed.root.runRelayTerms()
        XCTAssertNotNil(try rig.bed.row(), "nothing ends in the background")
        XCTAssertEqual(try termReadAt(rig), first)
        let before = try rig.center.handledEvents
        rig.bed.root.env.setActive(true)
        // The return writes the device record (`touchIfStale`, never written on this bed): the relay refuses the phone's
        // first save since the expiry, and the center's read on the `ENTITLEMENT_INACTIVE` it brings would supersede
        // the term's read, which then waits (#1771). Its handling ends first.
        try await handled(rig, after: before)
        await rig.bed.root.runRelayTerms()
        XCTAssertNil(try rig.bed.row(), "the next foreground ends it")
    }

    /// Review M3: a paying-with-slot answer that overtakes a lapse in flight drops the mark that lapse wrote.
    func testALapseOvertakenByAPayingAnswerLeavesNoMark() async throws {
        let rig = try await rig()
        let mac = rig.bed.mac.deviceID
        let lapse = Task { await rig.session.lapseRelay() }
        await Task.yield()
        await rig.session.relayAccountAnswered(paying: true, macs: [mac])
        await lapse.value
        XCTAssertNil(try rig.bed.row()?.link.relayRefused)
        XCTAssertTrue(rig.session.waitsForKeybox, "the key source stays")
    }

    /// Review M3, PR C final review M4: a superseded `syncThenLapse` does not lapse; the newest read that finishes decides.
    /// The test sets the order: the relay's `ENTITLEMENT_EXPIRED` read is in flight (it answered "expired") when a newer
    /// read starts (it answered paying); the lapse's read lands first, overtaken, then the newer one. The phone's last
    /// read had failed, so no paying phase holds the lapse back: only the superseded guard does.
    func testASupersededLapseReadDoesNotLapse() async throws {
        var made: SubmitGateHTTP?
        let rig = try await rig { inner in
            let gate = SubmitGateHTTP(inner: inner)
            made = gate
            return gate
        }
        let gate = try XCTUnwrap(made)
        let center = try rig.center
        let mac = rig.bed.mac.deviceID
        // The socket's `.reachable(true)` is the first event: its pass reads paying.
        try await poll({ center.handledEvents == 1 && center.phase == .paying(grace: false, macs: [mac]) }, "the first pass")
        rig.bed.fake.failNext("getAccountState", with: .unspecified)
        await center.refresh()
        XCTAssertEqual(center.phase, .unknown, "the last read failed")

        gate.holdReadAnswers()
        try await entitlement(rig.bed, "expired") // ENTITLEMENT_EXPIRED: the center's syncThenLapse reads
        try await poll({ gate.heldReads == 1 }, "the lapse's read answered \"expired\" and waits")
        try await entitlement(rig.bed, "active")
        let newer = Task { await center.refresh() }
        try await poll({ gate.heldReads == 2 }, "the newer read answered paying and waits")

        gate.releaseFirstRead() // the lapse's read lands, overtaken
        try await poll({ center.handledEvents == 2 }, "the expiry's handling ended")
        XCTAssertNil(try rig.bed.row()?.link.relayRefused, "the overtaken lapse read lapsed nothing")
        XCTAssertEqual(center.phase, .unknown, "its answer was dropped")

        gate.releaseReads() // the newer read lands: paying
        await newer.value
        await center.lapseEndsFinished()
        XCTAssertEqual(center.phase, .paying(grace: false, macs: [mac]))
        XCTAssertNil(try rig.bed.row()?.link.relayRefused, "no lapse marked a paying phone")
        XCTAssertTrue(rig.session.waitsForKeybox, "the key source stays")
    }

    /// Review M4: two relay-only Macs whose terms end in one foreground each get their notice, one at a time.
    func testTwoHubsEndingInOneForegroundEachGetTheirNotice() async throws {
        let home = "40E00000-0000-4000-8000-000000000004"
        let rig = try await rig(secondRelayHub: home)
        let homeSession = try XCTUnwrap(rig.bed.root.env.session(home), "the second Mac's session")
        let mark = try await refused(rig)
        // The second Mac has no keys on the bed, so its follower cannot decide: its mark is written as the follower would.
        var homeLink = try XCTUnwrap(try rig.bed.registry.row(home)?.link)
        homeLink.relayRefused = RelayRefusedRecord(since: mark.since, cause: .lapse)
        XCTAssertTrue(rig.bed.root.persistRoute(homeLink))
        XCTAssertNotNil(homeSession)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row())
        XCTAssertNil(try rig.bed.registry.row(home))
        XCTAssertEqual(rig.bed.root.linking.termNotices.count, 2)
        guard case .relayEnded(macName: "Work Mac", _) = rig.bed.root.linking.notice else {
            return XCTFail("first: \(String(describing: rig.bed.root.linking.notice))")
        }
        rig.bed.root.linking.dismissNotice()
        XCTAssertEqual(rig.bed.root.linking.notice, .relayEnded(macName: "Home Mac", notSent: 0))
    }

    /// Review M4: the farewell the relay refuses (the phone does not pay) stays in the send queue, is kept across the
    /// wipe, and is sent again at the next foreground, holding nothing back.
    func testARefusedFarewellIsKeptAndRetriedAtTheTerm() async throws {
        let rig = try await rig(farewellLive: true)
        _ = try await refused(rig)
        rig.bed.clock.advance(22 * day)
        await foreground(rig)
        rig.bed.clock.advance(300)
        await foreground(rig)
        XCTAssertNil(try rig.bed.row())
        XCTAssertEqual(try rig.bed.registry.pendingFarewells().map(\.hubID), [hubID], "the refused farewell is kept")
        await foreground(rig)
        XCTAssertEqual(rig.bed.farewellResends, [hubID], "sent again at the next foreground")
        XCTAssertEqual(try rig.bed.registry.pendingFarewells().map(\.hubID), [hubID], "refused again: still kept")
    }
}
