import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Mac's Connection section over the live root (relay client Phase 4 Task 8, `Bed`: CloudKit in memory, the relay on
/// `FakeHostedRelay`): a press reaches the upgrade or the request, the screen is rebuilt from the row alone, and an empty
/// origin keeps today's list.
@MainActor
final class MacTransportWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    // MARK: - An empty origin

    func testAnEmptyOriginKeepsTheMacsListAsToday() async throws {
        let (bed, session) = try await upgradeBed(relayOff: true)
        let row = try XCTUnwrap(try bed.row())

        XCTAssertNil(bed.root.env.relayAccount)
        let env = bed.root.env
        XCTAssertFalse(MacsView.opensDetail(account: env.relayAccount, availability: env.relay.availability, row: row, session: session))
        // Forget stays where it is: the row's own action, offered by the same rule.
        let item = try XCTUnwrap(bed.root.env.hubListItems(bed.root.linking.links, now: Date()).first { $0.id == hubID })
        XCTAssertNil(item.transportLine)
        XCTAssertEqual(MacsModel.action(for: item), .unlink)
        XCTAssertTrue(MacsView.offersRemoval(backend: .live))
    }

    func testARowOpensTheScreenOnlyForALinkedMacWithASessionAndAnAccount() async throws {
        let (bed, session) = try await upgradeBed()
        let store = FakeSubscriptionStore()
        let center = RelayAccountCenter(
            link: RelayAccountLink(hasIdentity: { false }, account: { nil }, events: { nil }), store: store,
            defaults: try XCTUnwrap(UserDefaults(suiteName: "mac-transport-\(UUID().uuidString)"))
        ) { [] }
        let availability = RelayAvailability.available(try RelayOrigin("https://relay.example.com"))
        var row = try XCTUnwrap(try bed.row())

        XCTAssertTrue(MacsView.opensDetail(account: center, availability: availability, row: row, session: session))
        XCTAssertFalse(MacsView.opensDetail(account: nil, availability: availability, row: row, session: session))
        XCTAssertFalse(MacsView.opensDetail(account: center, availability: .off(.notConfigured), row: row, session: session))
        XCTAssertFalse(MacsView.opensDetail(account: center, availability: availability, row: row, session: nil))
        XCTAssertFalse(MacsView.opensDetail(account: center, availability: availability, row: nil, session: session))
        row.state = .unlinkedByMac
        XCTAssertFalse(MacsView.opensDetail(account: center, availability: availability, row: row, session: session))
    }

    // MARK: - Choosing

    func testChoosingRelayRunsTheUpgrade() async throws {
        let (bed, session) = try await upgradeBed()

        await MacTransportPress.run(.chooseRelay, session: session, center: nil)

        XCTAssertEqual(bed.relayOps.ops, ["accountState", "vouch \(bed.mac.deviceID)", "addSlot \(bed.mac.deviceID)"])
        let link = try XCTUnwrap(try bed.row()?.link)
        let step = try XCTUnwrap(link.relayUpgrade?.step)
        XCTAssertTrue(link.relayUpgrade?.isPending == true)
        let facts = SessionTransportFacts(link: link, store: session.store, now: Date())
        XCTAssertEqual(facts.upgradeStep, step)
        XCTAssertNil(facts.upgradeRefusal)
    }

    func testChoosingICloudSendsARequest() async throws {
        let (bed, session) = try await relayBed()

        await MacTransportPress.run(.chooseICloud, session: session, center: nil)
        await session.outbox.drain()

        let record = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNil(record.reason)
        XCTAssertTrue(record.isOpen)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.map(\.id), [record.controlID])
    }

    func testChoosingICloudOnALapsedPhoneCarriesTheReason() async throws {
        let (bed, session) = try await relayBed()
        let account = AccountBed()
        let center = account.makeCenter()
        center.start()
        XCTAssertEqual(center.phase, .free(ended: false))
        XCTAssertEqual(center.switchReason, TransportFollowerPolicy.lapseReason)

        await MacTransportPress.run(.chooseICloud, session: session, center: center)

        XCTAssertEqual(try bed.row()?.link.transportRequest?.reason, TransportFollowerPolicy.lapseReason)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.first?.reason, TransportFollowerPolicy.lapseReason, "the hub spares its other phones")
    }

    func testTryAgainOnARequestKeepsItsReasonAndOnARefusedUpgradeUpgrades() async throws {
        let (bed, session) = try await relayBed()
        await session.outbox.holdFlushes()
        _ = await session.requestTransport(reason: "because")
        bed.clock.advance(25 * 3600)
        await bed.root.resumeRelayUpgrades()
        let ended = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertEqual(ended.refusal, .macNoAnswer)

        await MacTransportPress.run(.tryAgain, session: session, center: nil)

        let fresh = try XCTUnwrap(try bed.row()?.link.transportRequest)
        XCTAssertNotEqual(fresh.controlID, ended.controlID)
        XCTAssertEqual(fresh.reason, "because")
        XCTAssertTrue(fresh.isOpen)

        let (upgradeBed, upgradeSession) = try await upgradeBed()
        var link = try XCTUnwrap(try upgradeBed.row()?.link)
        link.relayUpgrade = RelayUpgradeRecord(step: .requested, refusal: .unavailable)
        XCTAssertTrue(try upgradeBed.registry.updateLink(link))

        await MacTransportPress.run(.tryAgain, session: upgradeSession, center: nil)

        XCTAssertNil(try upgradeBed.row()?.link.relayUpgrade?.refusal)
        XCTAssertEqual(upgradeBed.relayOps.count("vouch"), 1)
    }

    func testAnUpgradeThatDecidedNothingReadsTheAccountAgain() async throws {
        let (bed, session) = try await upgradeBed()
        bed.relayOps.fail("accountState", with: HostedRelayPairing.Refusal.unreachable)
        let asked = AskCounter()
        let center = RelayAccountCenter(
            link: RelayAccountLink(hasIdentity: { true }, account: { asked.count += 1; return nil }, events: { nil }),
            store: FakeSubscriptionStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: "mac-transport-\(UUID().uuidString)"))
        ) { [] }
        center.start()
        await center.passTask?.value
        let before = asked.count

        await MacTransportPress.run(.chooseRelay, session: session, center: center)

        XCTAssertNil(try bed.row()?.link.relayUpgrade, "nothing decided, nothing written")
        XCTAssertGreaterThan(asked.count, before, "so S54 shows when the relay really is out")
    }

    /// The account read is stale after this session's own upgrades: the upgrader reads the relay itself and the center
    /// is not told. A fourth Mac's refusal must still reach the screen, not fall back to the row the owner just pressed.
    func testASlotsFullRefusalShowsThoughTheAccountReadWasStale() async throws {
        let (bed, session) = try await upgradeBed()
        let phone = bed.phone.deviceID
        // This Mac is not on the subscription (the bed's stand paired it).
        try await HostedRelayPairing(session: try XCTUnwrap(bed.rootRelay.session())).removeSlot(mac: bed.mac.deviceID)
        for seed in [UInt8(21), 22] {
            try await bed.fake.pair(mac: try await macOnTheStand(bed, seed: seed), phones: [phone])
        }
        let center = RelayAccountCenter(
            link: .live(bed.rootRelay), store: FakeSubscriptionStore(),
            defaults: try XCTUnwrap(UserDefaults(suiteName: "mac-transport-\(UUID().uuidString)"))
        ) { [] }
        center.start()
        await center.foreground()?.value
        guard case .paying(_, let before) = center.phase else { return XCTFail("\(center.phase)") }
        XCTAssertEqual(before.count, 2)

        // A third Mac's upgrade fills the slots; the center still reads two, so this Mac offers Relay.
        try await bed.fake.pair(mac: try await macOnTheStand(bed, seed: 23), phones: [phone])
        XCTAssertEqual(try model(bed, session, phase: center.phase).rows.first?.action, .chooseRelay)
        bed.relayOps.fail("addSlot", with: HostedRelayPairing.Refusal.slotsFull(macs: ["a", "b", "c"]))

        await MacTransportPress.run(.chooseRelay, session: session, center: center)

        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.refusal, .vouch(.slotsFull))
        let row = try model(bed, session, phase: center.phase).rows.first
        XCTAssertEqual(row?.line, "Your subscription already has 3 Macs.")
        XCTAssertEqual(row?.action, .manageMacs)
    }

    /// A Relay link with no `ordered_actions`: `requestTransport` refuses before it writes anything, so the screen must not
    /// offer the press.
    func testARelayHubWithNoOrderedActionsOffersNoDeadICloudPress() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try bed.session()
        await session.waitForBoot()
        try await bed.publishGrant(ordered: false)
        await bed.fetch(session)
        let outcome = await session.requestTransport(reason: nil)
        XCTAssertEqual(outcome, .refused(.notOrdered), "the press this row must not offer")
        XCTAssertNil(try bed.row()?.link.transportRequest)

        let row = try model(bed, session).rows.last

        XCTAssertEqual(row?.line, "Update Watchtower on Work Mac to change how it connects.")
        XCTAssertEqual(row?.enabled, false)
        XCTAssertNil(row?.action)
    }

    // MARK: - How it ends

    func testAFinishedSwitchEndsBusy() async throws {
        let (bed, session) = try await relayBed()
        await MacTransportPress.run(.chooseICloud, session: session, center: nil)
        await session.outbox.drain()
        XCTAssertEqual(try model(bed, session).busyLine, "Switching to iCloud…")

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        let second = try await bed.fetchAndFollow(session)

        let after = try model(bed, second)
        XCTAssertNil(after.busyLine)
        XCTAssertEqual(after.rows.last?.chosen, true, "on iCloud now")
    }

    func testARefusalIsKeptAcrossARelaunch() async throws {
        let (bed, session) = try await upgradeBed()
        try await bed.fake.pair(mac: bed.mac.deviceID, phones: [bed.phone.deviceID])
        await MacTransportPress.run(.chooseRelay, session: session, center: nil)
        await session.outbox.drain()
        XCTAssertEqual(try bed.row()?.link.relayUpgrade?.step, .requested)
        try await bed.writeRejection(RelayUpgrade.notSupported, on: .cloudKit)
        await bed.fetch(session)
        await session.relayUpgrader?.idle()
        let line = "Work Mac can't switch to Relay. Update Watchtower on the Mac."
        XCTAssertEqual(try model(bed, session).rows.first?.line, line)

        try await bed.relaunch(self)
        let relaunched = try bed.session()
        await relaunched.waitForBoot()

        let again = try model(bed, relaunched)
        XCTAssertEqual(again.rows.first?.line, line)
        XCTAssertEqual(again.rows.first?.action, .tryAgain)
    }

    func testASecondPressStartsNothing() async throws {
        let (bed, session) = try await relayBed()
        await MacTransportPress.run(.chooseICloud, session: session, center: nil)
        let first = try XCTUnwrap(try bed.row()?.link.transportRequest)
        await MacTransportPress.run(.chooseICloud, session: session, center: nil)
        await session.outbox.drain()
        XCTAssertEqual(try bed.row()?.link.transportRequest?.controlID, first.controlID)
        let onCloud = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(onCloud.count, 1)

        let (upgrading, upgradeSession) = try await upgradeBed()
        await MacTransportPress.run(.chooseRelay, session: upgradeSession, center: nil)
        let step = try upgrading.row()?.link.relayUpgrade?.step
        await MacTransportPress.run(.chooseRelay, session: upgradeSession, center: nil)
        XCTAssertEqual(upgrading.relayOps.count("addSlot"), 1, "the slot was added once")
        XCTAssertEqual(try upgrading.row()?.link.relayUpgrade?.step, step)
    }

    // MARK: - The rest of the screen

    func testForgetStaysEnabledWhileWaiting() async throws {
        let (bed, session) = try await upgradeBed()
        await MacTransportPress.run(.chooseRelay, session: session, center: nil)
        XCTAssertNotNil(try model(bed, session).busyLine)
        XCTAssertFalse(bed.root.linking.isBusy)
        XCTAssertFalse(MacDetailView.forgetDisabled(linkingBusy: bed.root.linking.isBusy))

        await bed.root.linking.unlink(hubID)

        XCTAssertNil(try bed.row(), "the Mac goes while its switch waits")
    }

    func testManageMacsOpensTheSlotsScreen() async throws {
        let (bed, session) = try await upgradeBed()
        bed.relayOps.slots = ["a", "b", "c"]
        let linking = bed.root.linking

        let manage = try model(bed, session, phase: .paying(grace: false, macs: bed.relayOps.slots))
        XCTAssertEqual(manage.rows.first?.action, .manageMacs)

        await linking.manageSlots(for: hubID)

        XCTAssertEqual(linking.relaySlots.finishing, hubID)
        XCTAssertEqual(Set(linking.relaySlots.macs), ["a", "b", "c"])
        linking.closeSlots()
        XCTAssertNil(linking.relaySlots.finishing)
        XCTAssertEqual(bed.relayOps.count("vouch"), 0, "the screen itself starts no upgrade")
    }

    func testTheGrantIsReadFromTheSessionsKeybox() async throws {
        let (bed, session) = try await upgradeBed()
        let link = try XCTUnwrap(try bed.row()?.link)
        XCTAssertEqual(MacDetailView.grant(of: link, session: session)?.relayDeviceID, bed.mac.deviceID)
        XCTAssertEqual(MacDetailView.grant(of: link, session: session)?.runsOrderedActions, true)
    }

    // MARK: - The subscription screen

    func testSubscribeRowsOpenTheSubscriptionScreen() async throws {
        let origin = RelayAvailability.available(try RelayOrigin("https://relay.example.com"))
        // The Relay card: S01, S06, S55.
        var opened = 0
        let cards: [RelayCardModel?] = [
            RelayCardModel(availability: origin, phase: .free(ended: false), unconfirmedPurchase: false),
            RelayCardModel(availability: origin, phase: .free(ended: true), unconfirmedPurchase: false),
            RelayCardModel(availability: origin, phase: .free(ended: false), unconfirmedPurchase: true)
        ]
        for card in cards {
            let action = try XCTUnwrap(card?.action)
            XCTAssertEqual(action, .openSubscription)
            RelaySubscriptionPress.card(action, center: nil) { opened += 1 }
        }
        XCTAssertEqual(opened, cards.count)

        // The Connection row: S10.
        let (bed, session) = try await upgradeBed()
        let row = try XCTUnwrap(try model(bed, session, phase: .free(ended: false)).rows.first)
        XCTAssertEqual(row.action, .openSubscription)
        var routed: [String] = []
        MacDetailView.route(
            try XCTUnwrap(row.action), openSubscription: { routed.append("subscription") }, manageMacs: { routed.append("macs") },
            start: { _ in routed.append("started") }
        )
        XCTAssertEqual(routed, ["subscription"])
    }

    func testTheMovedCardRestoresOnTheSubscriptionScreen() async throws {
        let bed = AccountBed()
        let token = try await bed.register()
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        bed.emit(.control(kind: .subscriptionMoved, detail: ""))
        while center.phase != .moved { await Task.yield() }
        let origin = RelayAvailability.available(try RelayOrigin("https://relay.example.com"))
        let card = try XCTUnwrap(RelayCardModel(availability: origin, phase: center.phase, unconfirmedPurchase: false))
        XCTAssertEqual(card.action, .restore, "S41")
        let product = RelayProduct(id: "relay", displayPrice: "$4.99")
        bed.store.productResult = product
        func shown() -> RelaySubscriptionModel {
            RelaySubscriptionModel(
                purchase: center.purchase, unconfirmed: center.unconfirmed, phase: center.phase,
                config: RelayConfig(origin: nil), product: center.product
            )
        }

        bed.store.parkRestore()
        var opened = 0
        let first = try XCTUnwrap(RelaySubscriptionPress.card(try XCTUnwrap(card.action), center: center) { opened += 1 })
        XCTAssertEqual(opened, 1, "the screen opens with the press, not after it")
        while !bed.store.restoreIsParked { await Task.yield() }
        XCTAssertEqual(shown().primary?.title, "Restoring…", "S44")
        XCTAssertFalse(shown().showsRestore)
        bed.store.releaseRestore()
        await first.value
        XCTAssertEqual(bed.store.restoreCalls, 1)
        XCTAssertEqual(shown().line, "No subscription found on this Apple ID.", "S45")
        XCTAssertEqual(shown().primary?.title, "Subscribe — $4.99 / month", "S45 still sells: the press loaded the price")

        center.screenClosed()
        bed.store.restoreResult = bed.row(token: token)
        bed.fake.failNext("submitTransaction", with: .invalidTransaction)
        await RelaySubscriptionPress.card(.restore, center: center) {}?.value
        XCTAssertEqual(shown().line, "Relay couldn't confirm this purchase. Try Restore Purchases.", "S27")
        XCTAssertEqual(shown().primary?.action, .manageSubscription)
        XCTAssertTrue(shown().showsRestore)
    }

    func testTheCardsRetryReadsTheAccountAndOpensNothing() async throws {
        let bed = AccountBed()
        try await bed.register()
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        let reads = bed.ops.filter { $0 == "getAccountState" }.count
        var opened = 0
        await RelaySubscriptionPress.card(.retry, center: center) { opened += 1 }?.value
        XCTAssertEqual(opened, 0)
        XCTAssertEqual(bed.ops.filter { $0 == "getAccountState" }.count, reads + 1)
    }

    // MARK: - Helpers

    private func model(
        _ bed: Bed, _ session: HubSession, phase: RelayAccountCenter.Phase = .paying(grace: false, macs: [])
    ) throws -> MacTransportModel {
        let link = try XCTUnwrap(try bed.row()?.link)
        return MacTransportModel(
            link: link, grant: MacDetailView.grant(of: link, session: session), phase: phase, unconfirmedPurchase: false,
            availability: .available(try RelayOrigin("https://relay.example.com")),
            session: SessionTransportFacts(link: link, store: session.store, now: Date()),
            macName: link.macName, ownDeviceID: link.deviceID, now: Date()
        )
    }

    private func upgradeBed(relayOff: Bool = false) async throws -> (Bed, HubSession) {
        let bed = try await Bed.make(self, on: .cloudKit, macRelayID: false, relayOff: relayOff)
        try await bed.fake.pair(mac: bed.mac.deviceID, phones: [])
        let session = try bed.session()
        await session.waitForBoot()
        try await bed.publishGrant(ordered: true, macRelay: true)
        await bed.fetch(session)
        await session.epochAckWork?.value
        await session.outbox.drain()
        return (bed, session)
    }

    /// Another Mac registered on the bed's relay, ready to fill a slot.
    private func macOnTheStand(_ bed: Bed, seed: UInt8) async throws -> String {
        let clock = ManualRelayClock(now: Date())
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: seed, count: 32))
        let mac = HostedRelayClient(
            origin: try RelayOrigin(bed.fake.origin), signer: Ed25519RelaySigner(key), kind: .mac,
            attestor: RelayAttestor(attest: FakeAppAttest(), keys: InMemoryAppAttestKeyStore(), clock: clock),
            http: bed.fake.http, sockets: bed.fake.sockets, clock: clock
        )
        _ = try await mac.register()
        return mac.deviceID
    }

    private func relayBed() async throws -> (Bed, HubSession) {
        let bed = try await Bed.make(self, on: .relay)
        return (bed, try await bed.orderedSession())
    }
}

private final class AskCounter: @unchecked Sendable {
    var count = 0
}
