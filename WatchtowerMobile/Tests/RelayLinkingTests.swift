import Foundation
import WatchtowerE2ETesting
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

private let hub = TestE2E.hubID.uuidString
private let otherHub = "07E40000-0000-4000-8000-000000000003"
private let thirdHub = "5D0D1000-0000-4000-8000-000000000002"

/// `UserDefaults` that drops writes of one key while `refusing` (a failed `UserDefaults` write).
private final class RefusingDefaults: UserDefaults {
    var refusing: String?

    override func set(_ value: Any?, forKey defaultName: String) {
        guard defaultName != refusing else { return }
        super.set(value, forKey: defaultName)
    }
}

/// Linking from the phone over the relay (relay client Phase 3 Task 10): the route, the pairing slot, the owner's
/// confirmation, vouch and promote, the promoted states and their resume, cancel, the slot removals, the three-slots
/// screen, and a Mac on Relay refused on the iCloud path. The relay is a scripted account (`FakeRelayOps`), the
/// app side `FakeLinkHost` (its pair zones keep every hello written), the Mac a scripted keybox answer.
@MainActor
final class RelayLinkingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let identity = DeviceIdentity(
        deviceID: TestE2E.deviceID.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0"
    )
    private let owner = "_owner-acme"
    private let mac = RelayTestMac(seed: 7)
    private let otherMac = RelayTestMac(seed: 9)

    private var log: LinkEventLog!
    private var container: FakeLinkAccess!
    private var host: FakeLinkHost!
    private var clock: FakeLinkClock!
    private var defaults: UserDefaults!
    private var keyStore: InMemoryPhoneKeyStore!
    private var relay: FakeRelayOps!

    override func setUp() async throws {
        keyStore = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        log = LinkEventLog()
        container = FakeLinkAccess(log: log)
        container.userRecordNameValue = owner
        host = FakeLinkHost(log: log)
        host.keys = keyStore
        clock = FakeLinkClock(now: start)
        defaults = try makeDefaults()
        relay = FakeRelayOps(clock: clock)
    }

    // MARK: - Helpers

    private func makeModel(relay ops: (any RelayLinkOps)? = nil) -> LinkingViewModel {
        let model = LinkingViewModel(
            access: container, store: LinkStore(defaults: defaults), identity: identity, keys: keyStore, clock: clock,
            relay: ops ?? relay
        )
        model.host = host
        return model
    }

    private var store: LinkStore { LinkStore(defaults: defaults) }

    private func relayCode(
        _ hubID: String = hub,
        macName: String = "build-box",
        cloudKit: Bool = false,
        issuedAgo: TimeInterval = 10,
        by relayMac: RelayTestMac? = nil
    ) -> LinkPayload {
        (relayMac ?? mac).code(
            hubID: hubID, macName: macName, owner: owner, now: clock.now(), transport: .relay, cloudKit: cloudKit,
            issuedAgo: issuedAgo
        )
    }

    /// The Mac links any device record carrying `payload`'s nonce.
    private func macLinks(_ payload: LinkPayload) {
        macLinks([payload])
    }

    private func macLinks(_ payloads: [LinkPayload]) {
        let identity = identity
        let clock = clock
        host.mac = { writes in
            guard let payload = payloads.last(where: { code in writes.contains { $0.linkNonce == code.nonce } }) else { return nil }
            return DeviceGrant(
                deviceID: identity.deviceID ?? "", hubID: payload.hubID, name: identity.name, scope: .private, linked: true,
                linkRefused: nil, linkedAt: clock?.now(), typingAllowed: false, startSessionsAllowed: true,
                decidedAt: clock?.now() ?? Date()
            )
        }
    }

    private func keysHeld(_ hubID: String = hub) throws -> Bool {
        try keyStore.hubLink(hubID) != nil
    }

    /// A confirmed link of `payload`'s hub as an earlier run left it: the keys in the Keychain and the entry in
    /// `LinkStore.promoted` in `state`.
    @discardableResult
    private func seedPromoted(
        _ payload: LinkPayload,
        state: PromotedLink.State,
        slot: String = "slot-0",
        expiresIn: TimeInterval = 600,
        vouchedAgo: TimeInterval? = nil
    ) throws -> PromotedLink {
        let scanned = try ScannedHubKeys(payload)
        try keyStore.saveHubLink(try scanned.unconfirmedLink.adding(TestPhone.keyboxKeys()))
        var record = LinkRecord(
            hubID: payload.hubID, macName: payload.macName, scope: .private, ownerName: payload.ownerUser ?? "",
            userRecordName: "", nonce: payload.nonce, dataShareURL: nil, relayShareURL: nil, deviceID: identity.deviceID,
            linkedAt: clock.now(), relayAuthPub: payload.relayAuthPub, hubTransports: payload.transports
        )
        record.setRelay(mac: payload.relayDeviceID ?? "")
        let link = PromotedLink(
            link: record, slot: slot, slotExpiresAt: clock.now().addingTimeInterval(expiresIn), state: state,
            since: clock.now(), vouchedAt: vouchedAgo.map { clock.now().addingTimeInterval(-$0) }
        )
        var all = store.promoted
        all[link.hubID] = link
        store.promoted = all
        return link
    }

    /// A saved Relay link to `relayMac` (a registry row).
    private func seedRelayRow(_ hubID: String, macName: String, relayMac: RelayTestMac) {
        var record = LinkRecord(
            hubID: hubID, macName: macName, scope: .private, ownerName: owner, userRecordName: "", nonce: "n",
            dataShareURL: nil, relayShareURL: nil, deviceID: identity.deviceID, linkedAt: start
        )
        record.setRelay(mac: relayMac.deviceID)
        host.seed(record)
    }

    private func state(_ hubID: String = hub) -> PromotedLink.State? {
        store.promoted[hubID]?.state
    }

    /// One full relay link of `payload`, the owner confirming at once.
    private func link(_ payload: LinkPayload, model: LinkingViewModel) async {
        macLinks(payload)
        await model.open(payload.url())
    }

    // MARK: - The link

    func testAPhoneLinksAHubOverAPairingSlot() async throws {
        let payload = relayCode()
        let model = makeModel()

        await link(payload, model: model)

        XCTAssertEqual(model.phase, .linked(macName: "build-box"))
        XCTAssertEqual(host.pairings.map(\.slot), ["slot-1"])
        XCTAssertEqual(host.pairings.first?.mac, mac.deviceID)
        let hellos = try await host.pairHellos()
        XCTAssertEqual(hellos.count, 1, "the hello goes only into pair/<slot>")
        XCTAssertEqual(relay.ops, ["accountState", "open \(mac.deviceID)", "vouch \(mac.deviceID)", "promote slot-1"])
        XCTAssertEqual(relay.slots, [mac.deviceID], "the Mac holds a slot")
        XCTAssertEqual(host.linkedCalls.last?.record.route, .hostedRelay(macDeviceID: mac.deviceID))
        XCTAssertEqual(host.prepared, [.hostedRelay(macDeviceID: mac.deviceID)], "the data zone after promote, on the same route")
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertNil(store.pending)
        XCTAssertTrue(try keysHeld())
    }

    func testTheHelloCarriesThePhonesRelayDeviceID() async throws {
        await link(relayCode(), model: makeModel())

        let hellos = try await host.pairHellos()
        let hello = try XCTUnwrap(hellos.first)
        XCTAssertEqual(hello.relayDeviceID, FakeRelayOps.phoneID)
        XCTAssertTrue(RelayIDs.isValid(try XCTUnwrap(hello.relayDeviceID)))
    }

    func testARelayLinkNeedsNoICloudAccount() async throws {
        container.status = .noAccount
        let model = makeModel()

        await link(relayCode(), model: model)

        XCTAssertEqual(model.phase, .linked(macName: "build-box"))
        // An iCloud account change never touches a Relay link (R19).
        await model.finish()
        container.status = .available
        container.userRecordNameValue = "_someone-else"
        await model.accountChanged()
        XCTAssertEqual(model.links.map(\.hubID), [hub])
        XCTAssertTrue(try keysHeld())
    }

    // MARK: - Before the owner confirmed

    func testSlotsFullRefusesBeforeAnyHello() async throws {
        relay.slots = ["m1", "m2", "m3"]
        let model = makeModel()

        await model.open(relayCode().url())

        XCTAssertEqual(model.phase, .slotsFull(macName: "build-box"))
        XCTAssertEqual(model.relaySlots.macs, ["m1", "m2", "m3"])
        XCTAssertTrue(host.pairings.isEmpty, "no pairing transport, no hello")
        XCTAssertFalse(try keysHeld(), "nothing written")
        XCTAssertNil(store.pending)
    }

    func testSlotsFullBeforeConfirmationShowsTheSlotsScreenInline() async throws {
        seedRelayRow(otherHub, macName: "Work Mac", relayMac: otherMac)
        let finishing = relayCode(thirdHub, macName: "Home Mac", by: RelayTestMac(seed: 11))
        try seedPromoted(finishing, state: .confirmed)
        relay.slots = [otherMac.deviceID, "unknown-mac", RelayTestMac(seed: 11).deviceID]
        let model = makeModel()

        await model.open(relayCode().url())

        XCTAssertEqual(model.phase, .slotsFull(macName: "build-box"))
        let screen = RelaySlotsModel(state: model.relaySlots, links: model.links, promoted: model.promotedLinks)
        XCTAssertEqual(screen.rows.map(\.name), ["Work Mac", "A Mac not on this iPhone", "Home Mac"])
        XCTAssertEqual(screen.rows.map(\.sub), [nil, nil, "Finishing link"])
        XCTAssertEqual(screen.rows.map(\.action), [.remove, .remove, .remove])
    }

    func testSlotsFullShowsTheMacsWithRemove() async throws {
        relay.slots = ["m1", "m2", "m3"]
        let model = makeModel()
        await model.open(relayCode().url())

        let screen = RelaySlotsModel(state: model.relaySlots, links: model.links, promoted: model.promotedLinks)
        XCTAssertEqual(screen.title, "Your subscription already has 3 Macs. Remove one to add this Mac over Relay.")
        XCTAssertEqual(screen.rows.count, 3)
        XCTAssertTrue(screen.rows.allSatisfy { $0.action.title == "Remove" && !$0.isDisabled })
        XCTAssertEqual(screen.footnote, "Up to 5 replacements in 30 days.")
    }

    func testRemovingAnUnknownSlotCallsRemoveSlotOnly() async throws {
        relay.slots = ["m1", "m2", "m3"]
        let payload = relayCode()
        macLinks(payload)
        let model = makeModel()
        await model.open(payload.url())

        await model.removeFromSlots("m2")

        XCTAssertTrue(relay.ops.contains("removeSlot m2"))
        XCTAssertTrue(host.removedHubIDs.isEmpty, "no local link to end")
        XCTAssertEqual(model.phase, .linked(macName: "build-box"), "the link goes on with the same code")
        let hellos = try await host.pairHellos()
        XCTAssertEqual(hellos.count, 1)
    }

    func testRemovingALinkedMacUnlinksItThenLinksWithTheSameCode() async throws {
        seedRelayRow(otherHub, macName: "Work Mac", relayMac: otherMac)
        relay.slots = [otherMac.deviceID, "m2", "m3"]
        let payload = relayCode()
        macLinks(payload)
        let model = makeModel()
        await model.open(payload.url())
        XCTAssertEqual(model.phase, .slotsFull(macName: "build-box"))

        await model.removeFromSlots(otherMac.deviceID)

        XCTAssertEqual(host.removedHubIDs, [otherHub])
        XCTAssertEqual(host.farewells.map(\.route), [.hostedRelay(macDeviceID: otherMac.deviceID)], "the unlink's farewell")
        let freedAt = try XCTUnwrap(relay.ops.firstIndex(of: "removeSlot \(otherMac.deviceID)"))
        XCTAssertLessThan(freedAt, try XCTUnwrap(relay.ops.lastIndex(of: "open \(mac.deviceID)")), "the slot freed, then a new open")
        XCTAssertEqual(relay.count("open"), 2, "the pre-check's refused open, then the one after the removal")
        XCTAssertEqual(model.phase, .linked(macName: "build-box"))
    }

    func testRemoveFailureShowsTryAgain() async throws {
        relay.slots = ["m1", "m2", "m3"]
        relay.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        let model = makeModel()
        await model.open(relayCode().url())

        await model.removeFromSlots("m1")

        XCTAssertEqual(model.relaySlots.failed, "m1")
        let screen = RelaySlotsModel(state: model.relaySlots, links: model.links, promoted: model.promotedLinks)
        XCTAssertEqual(screen.title, "Couldn't remove the Mac. Try again.")
        XCTAssertEqual(screen.rows.first?.action, .tryAgain)
        XCTAssertEqual(screen.rows.first?.action.title, "Try Again")
        XCTAssertEqual(model.phase, .slotsFull(macName: "build-box"), "the link waits")
        XCTAssertTrue(host.slotRemovals.isEmpty, "a Mac not on this iPhone keeps no removal")
    }

    func testRemovingStateDisablesTheOtherRows() {
        let state = RelaySlotsState(macs: ["m1", "m2"], removing: "m1")
        let screen = RelaySlotsModel(state: state, links: [], promoted: [])
        XCTAssertEqual(screen.rows.map(\.action), [.removing, .remove])
        XCTAssertEqual(screen.rows.map(\.isDisabled), [false, true])
        XCTAssertEqual(RelaySlotsModel.Action.removing.title, "Removing…")
    }

    func testNotPayingAtOpenIsRefused() async throws {
        relay.fail("open", with: HostedRelayPairing.Refusal.notPaying)
        let model = makeModel()
        await model.open(relayCode().url())
        XCTAssertEqual(model.phase, .failed(.needsRelay(macName: "build-box")))

        relay.fail("open", with: HostedRelayPairing.Refusal.notPaying)
        model.dismiss()
        await model.open(relayCode(macName: "Work Mac", cloudKit: true).url())
        XCTAssertEqual(model.phase, .failed(.macOnRelay(macName: "Work Mac")))
        XCTAssertTrue(host.pairings.isEmpty)
        XCTAssertFalse(try keysHeld())
    }

    func testOpenUnreachableIsRelayUnreachable() async throws {
        for (error, failure) in [
            (HostedRelayPairing.Refusal.unreachable, LinkFailure.relayUnreachable),
            (.attestationBackoff(until: start), .relayUnreachable),
            (.updateRequired, .updateApp),
            (.replacementLimit, .relayReplacementLimit)
        ] {
            relay.fail("open", with: error)
            let model = makeModel()
            await model.open(relayCode().url())
            XCTAssertEqual(model.phase, .failed(failure), "\(error)")
        }
        XCTAssertTrue(host.pairings.isEmpty)
        XCTAssertFalse(try keysHeld())
    }

    func testAPairingPrepareFailureClosesTheSlot() async throws {
        host.pairingError = CocoaError(.fileWriteNoPermission)
        let model = makeModel()

        await model.open(relayCode().url())

        guard case .failed(.local) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(relay.ops.last, "close slot-1")
        XCTAssertFalse(try keysHeld(), "the keys go")
        XCTAssertNil(store.pending)
    }

    func testAHelloWriteFailureClosesTheSlot() async throws {
        host.pairSaveError = CocoaError(.fileWriteOutOfSpace)
        let model = makeModel()

        await model.open(relayCode().url())

        guard case .failed(.local) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(relay.ops.last, "close slot-1")
        XCTAssertFalse(try keysHeld())
    }

    func testNoAnswerClosesTheSlot() async throws {
        // Issued 200 s ago: the code's wait (exp + 120 s) ends before the slot's 600 s.
        let model = makeModel()
        await model.open(relayCode(issuedAgo: 200).url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(relay.ops.last, "close slot-1")
        XCTAssertFalse(try keysHeld())
    }

    func testAnExpiredSlotClosesAndAsksForANewCode() async throws {
        let model = makeModel()
        await model.open(relayCode().url())

        XCTAssertEqual(model.phase, .failed(.expired), "the slot's 600 s ran out first")
        XCTAssertEqual(relay.ops.last, "close slot-1")
        XCTAssertNil(store.pending)
    }

    func testTheHalfBeforePromoteIsBoundedByTheCodesDeadline() async throws {
        clock.parked = true
        let payload = relayCode(issuedAgo: 300)
        let model = makeModel()
        let flow = Task { await model.open(payload.url()) }
        try await poll { model.phase == .waiting(macName: "build-box") }

        let pending = try XCTUnwrap(store.pending)
        XCTAssertEqual(pending.deadline, Date(timeIntervalSince1970: TimeInterval(payload.exp) + LinkingViewModel.expiryGrace))
        XCTAssertEqual(pending.relaySlot, "slot-1")
        flow.cancel()
        await flow.value
    }

    // MARK: - After the owner confirmed: the live flow

    func testAPromoteRefusalInTheLiveFlowKeepsTheKeysAndAsksTheOwner() async throws {
        let table: [(HostedRelayPairing.Refusal, PromotedLink.Reason, String)] = [
            (.pairingExpired, .slotExpired, "The link timed out on Relay. Try again, or cancel it."),
            (.slotsFull(macs: []), .slotsFull, "Relay already has 3 Macs. Remove one, then try again, or cancel this link."),
            (.replacementLimit, .replacementLimit, "Too many Mac changes on Relay. Try again later, or cancel this link."),
            (.notPaying, .notPaying, "Relay isn't active on this iPhone. Try again when it is, or cancel this link.")
        ]
        for (refusal, reason, copy) in table {
            try await setUp()
            relay.fail("promote", with: refusal)
            let model = makeModel()

            await link(relayCode(), model: model)

            XCTAssertEqual(model.phase, .idle, "\(refusal): the scanner is free")
            XCTAssertEqual(state(), .needsOwner(reason))
            XCTAssertEqual(model.notice, .needsOwner(macName: "build-box", reason: reason))
            XCTAssertEqual(model.notice?.message, "\(copy) See Settings → Macs.")
            XCTAssertEqual(model.notice?.dismissTitle, "OK")
            XCTAssertTrue(try keysHeld(), "\(refusal): the keys stay")
            XCTAssertNil(store.pending)
        }
    }

    func testEveryVouchRefusalKeepsTheKeysAndAsksTheOwner() async throws {
        let table: [(HostedRelayPairing.VouchRefusal, PromotedLink.Reason?)] = [
            (.updateRequired, .updateApp), (.notPaying, .notPaying), (.hubNotOnRelay, .hubNotOnRelay),
            (.slotsFull, .slotsFull), (.notConfirmed, .notConfirmed), (.unreachable, nil),
            (.attestationBackoff(until: start), nil)
        ]
        for (refusal, reason) in table {
            try await setUp()
            relay.fail("vouch", with: refusal)
            let model = makeModel()

            await link(relayCode(), model: model)

            XCTAssertEqual(state(), reason.map { .needsOwner($0) } ?? .confirmed, "\(refusal)")
            XCTAssertEqual(relay.count("promote"), 0, "\(refusal): no promote without a vouch")
            XCTAssertTrue(try keysHeld(), "\(refusal)")
            XCTAssertEqual(model.phase, .idle)
            if reason == nil {
                XCTAssertEqual(model.notice, .finishingInBackground(macName: "build-box"))
                XCTAssertEqual(model.notice?.message, "build-box will finish linking in the background. See Settings → Macs.")
            }
        }
        XCTAssertEqual(
            PromotedLink.Reason.hubNotOnRelay.message(macName: "build-box"),
            "build-box isn't on Relay yet. Keep Watchtower open on it and try again, or cancel this link."
        )
        XCTAssertEqual(PromotedLink.Reason.updateApp.message(macName: "build-box"), "Update Watchtower to finish this link, or cancel it.")
        XCTAssertEqual(PromotedLink.Reason.notConfirmed.message(macName: "build-box"), "Relay didn't confirm the link. Try again, or cancel it.")
    }

    func testHubNotVouchedVouchesAgainOnce() async throws {
        relay.fail("promote", with: HostedRelayError.server(code: .hubNotVouched, retryAfter: nil))
        let model = makeModel()
        await link(relayCode(), model: model)
        XCTAssertEqual(model.phase, .linked(macName: "build-box"))
        XCTAssertEqual(relay.count("vouch"), 2)
        XCTAssertEqual(relay.count("promote"), 2)

        try await setUp()
        let twice = HostedRelayError.server(code: .hubNotVouched, retryAfter: nil)
        relay.fail("promote", with: twice, twice)
        let second = makeModel()
        await link(relayCode(), model: second)
        XCTAssertEqual(state(), .needsOwner(.notConfirmed))
        XCTAssertEqual(relay.count("promote"), 2, "promoted once more, never a third time")
    }

    func testAKillBetweenPromoteAndItsAnswerLeavesAPromoteSentRow() async throws {
        relay.losePromoteAnswer(HostedRelayPairing.Refusal.unreachable)
        let model = makeModel()
        await link(relayCode(), model: model)
        XCTAssertEqual(state(), .promoteSent, "the answer was lost")
        XCTAssertEqual(relay.slots, [mac.deviceID], "but the relay granted the slot")

        // Relaunch.
        let relaunched = makeModel()
        await relaunched.resumePromotedLinks()

        XCTAssertEqual(relay.count("promote"), 1, "no promote is sent again")
        XCTAssertEqual(relay.ops.suffix(1), ["accountState"])
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(host.linkedCalls.last?.record.route, .hostedRelay(macDeviceID: mac.deviceID))
    }

    func testTheConfirmedWriteIsRetriedBeforeVouch() async throws {
        let refusing = try XCTUnwrap(RefusingDefaults(suiteName: "relay-refusing-\(UUID().uuidString)"))
        refusing.refusing = "link.promoted"
        defaults = refusing
        let model = makeModel()
        let payload = relayCode()
        await link(payload, model: model)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertNotNil(store.pending, "the link stays in pending")
        XCTAssertEqual(relay.count("vouch"), 0, "no relay call before the confirmed write")

        refusing.refusing = nil
        let relaunched = makeModel()
        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .linked(macName: "build-box"))
        XCTAssertEqual(relay.ops.filter { !$0.hasPrefix("accountState") }, [
            "open \(mac.deviceID)", "vouch \(mac.deviceID)", "promote slot-1"
        ])
        XCTAssertEqual(host.pairings.map(\.slot), ["slot-1", "slot-1"], "the resume reads the same slot")
        let hellos = try await host.pairHellos()
        XCTAssertEqual(hellos.count, 1, "no second hello")
    }

    func testAPromotedLinkNeverHoldsTheLinkScreen() async throws {
        host.prepareError = CocoaError(.fileReadCorruptFile)
        let model = makeModel()

        await link(relayCode(), model: model)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, .finishingInBackground(macName: "build-box"))
        XCTAssertNil(store.pending)
        XCTAssertEqual(state(), .promoted)
        XCTAssertFalse(model.isBusy, "scanning is free")
    }

    func testAFailureAfterPromoteResumesWithoutASecondHelloOrPromote() async throws {
        host.prepareError = CocoaError(.fileReadCorruptFile)
        await link(relayCode(), model: makeModel())
        host.prepareError = nil

        let relaunched = makeModel()
        await relaunched.resumePromotedLinks()

        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(relay.count("promote"), 1)
        let hellos = try await host.pairHellos()
        XCTAssertEqual(hellos.count, 1)
        XCTAssertEqual(relaunched.links.map(\.hubID), [hub])
    }

    func testKilledPastTheDeadlineAfterPromoteResumesOnRelaunch() async throws {
        host.prepareError = CocoaError(.fileReadCorruptFile)
        let payload = relayCode()
        await link(payload, model: makeModel())
        host.prepareError = nil
        clock.advance(by: 3_600)
        XCTAssertGreaterThan(clock.now().timeIntervalSince1970, Double(payload.exp))

        let relaunched = makeModel()
        await relaunched.resumePromotedLinks()

        XCTAssertEqual(relaunched.links.first?.link.route, .hostedRelay(macDeviceID: mac.deviceID))
        XCTAssertEqual(relay.count("promote"), 1)
        XCTAssertEqual(relay.count("open"), 1)
    }

    func testAPromotedLinkKeepsResumingUntilItSucceeds() async throws {
        host.prepareError = CocoaError(.fileReadCorruptFile)
        await link(relayCode(), model: makeModel())
        for launch in 1...3 {
            let relaunched = makeModel()
            await relaunched.resumePromotedLinks()
            XCTAssertEqual(state(), .promoted, "launch \(launch)")
            let row = MacsModel.finishingRows(relaunched.promotedLinks, running: relaunched.resumer.running, failed: relaunched.resumer.failed)
            XCTAssertEqual(row.first?.status, .failed)
            XCTAssertEqual(row.first?.line, "Couldn't finish the link. Watchtower tries again when it opens.")
            XCTAssertEqual(row.first?.actions, [.tryAgain, .cancel])
        }
        host.prepareError = nil
        await makeModel().resumePromotedLinks()
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(relay.count("promote"), 1, "no pairing op while promoted")
        XCTAssertEqual(relay.count("vouch"), 1)
    }

    // MARK: - Resume per state

    func testAConfirmedLinkVouchesThenPromotesOnResume() async throws {
        try seedPromoted(relayCode(), state: .confirmed)

        await makeModel().resumePromotedLinks()

        XCTAssertEqual(relay.ops, ["vouch \(mac.deviceID)", "promote slot-0"])
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(host.linkedCalls.count, 1)
    }

    func testPromoteSentWithTheMacInSlotsBecomesPromotedWithoutPromoting() async throws {
        try seedPromoted(relayCode(), state: .promoteSent)
        relay.slots = [mac.deviceID]

        await makeModel().resumePromotedLinks()

        XCTAssertEqual(relay.ops, ["accountState"])
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(host.linkedCalls.count, 1)
    }

    func testPromoteSentWithAnOpenSlotPromotesAgainOnce() async throws {
        try seedPromoted(relayCode(), state: .promoteSent, vouchedAgo: 700)

        await makeModel().resumePromotedLinks()

        XCTAssertEqual(relay.ops, ["accountState", "vouch \(mac.deviceID)", "promote slot-0"], "vouched first: the vouch was 700 s old")
        XCTAssertTrue(store.promoted.isEmpty)

        try await setUp()
        try seedPromoted(relayCode(), state: .promoteSent, vouchedAgo: 60)
        await makeModel().resumePromotedLinks()
        XCTAssertEqual(relay.ops, ["accountState", "promote slot-0"], "a fresh vouch is enough")
    }

    func testPairingExpiredOnARelaunchRetryAsksTheOwnerAndTryAgainUsesANewSlot() async throws {
        try seedPromoted(relayCode(), state: .promoteSent, expiresIn: -1)
        let model = makeModel()

        await model.resumePromotedLinks()

        XCTAssertEqual(state(), .needsOwner(.slotExpired))
        XCTAssertEqual(relay.count("promote"), 0, "no promote of an expired slot")
        let row = try XCTUnwrap(MacsModel.finishingRows(model.promotedLinks, running: [], failed: []).first)
        XCTAssertEqual(row.line, "The link timed out on Relay. Try again, or cancel it.")
        XCTAssertEqual(row.actions.map(\.title), ["Try Again", "Cancel"])

        await model.tryAgain(hub)

        XCTAssertEqual(Array(relay.ops.suffix(4)), ["accountState", "open \(mac.deviceID)", "vouch \(mac.deviceID)", "promote slot-1"])
        XCTAssertTrue(host.pairings.isEmpty, "no pairing transport, no hello")
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(model.links.map(\.hubID), [hub])
    }

    func testDefiniteRefusalsAfterPromoteSentAskTheOwner() async throws {
        let table: [(HostedRelayPairing.Refusal, PromotedLink.Reason)] = [
            (.slotsFull(macs: []), .slotsFull), (.replacementLimit, .replacementLimit), (.notPaying, .notPaying)
        ]
        for (refusal, reason) in table {
            try await setUp()
            try seedPromoted(relayCode(), state: .promoteSent, vouchedAgo: 10)
            relay.fail("promote", with: refusal)

            await makeModel().resumePromotedLinks()

            XCTAssertEqual(state(), .needsOwner(reason), "\(refusal)")
            XCTAssertTrue(try keysHeld())
        }
    }

    func testNotFoundAndNotInSlotsKeepsTheKeysAndAsksTheOwner() async throws {
        try seedPromoted(relayCode(), state: .promoteSent, vouchedAgo: 10)
        relay.fail("promote", with: HostedRelayError.server(code: .notFound, retryAfter: nil))
        let model = makeModel()

        await model.resumePromotedLinks()

        XCTAssertEqual(state(), .needsOwner(.notConfirmed))
        XCTAssertTrue(try keysHeld())
        let row = try XCTUnwrap(MacsModel.finishingRows(model.promotedLinks, running: [], failed: []).first)
        XCTAssertEqual(row.line, "Relay didn't confirm the link. Try again, or cancel it.")

        await model.tryAgain(hub)
        XCTAssertEqual(Array(relay.ops.suffix(4)), ["accountState", "open \(mac.deviceID)", "vouch \(mac.deviceID)", "promote slot-1"])
        XCTAssertTrue(store.promoted.isEmpty)
    }

    func testNotFoundWithAnUnreachableAccountStateKeepsTheLinkAndRechecks() async throws {
        try seedPromoted(relayCode(), state: .confirmed)
        relay.fail("promote", with: HostedRelayError.server(code: .notFound, retryAfter: nil))
        relay.fail("accountState", with: URLError(.notConnectedToInternet))
        let model = makeModel()

        await model.resumePromotedLinks()
        // Vouched, promoted: NOT_FOUND, and the account check after it failed.
        XCTAssertEqual(relay.ops, ["vouch \(mac.deviceID)", "promote slot-0", "accountState"])
        XCTAssertEqual(state(), .promoteSent, "no state change")
        XCTAssertTrue(try keysHeld())

        clock.advance(by: PromotedLinkResumer.firstPause + 1)
        relay.slots = [mac.deviceID]
        await model.resumePromotedLinks()
        XCTAssertTrue(store.promoted.isEmpty, "the next pass rechecks and finds the Mac in slots")
    }

    func testNeedsOwnerWaitsForTheOwner() async throws {
        for reason in PromotedLink.Reason.allCases {
            try await setUp()
            try seedPromoted(relayCode(), state: .needsOwner(reason))
            await makeModel().resumePromotedLinks()
            XCTAssertTrue(relay.ops.isEmpty, "\(reason): nothing automatic")
            XCTAssertEqual(state(), .needsOwner(reason))
        }
    }

    func testTryAgainOpensANewSlotWithoutAHello() async throws {
        try seedPromoted(relayCode(), state: .needsOwner(.slotExpired))
        let model = makeModel()

        await model.tryAgain(hub)

        XCTAssertEqual(relay.ops, ["accountState", "open \(mac.deviceID)", "vouch \(mac.deviceID)", "promote slot-1"])
        XCTAssertTrue(host.pairZones.isEmpty, "no record written in any pair zone")
        XCTAssertEqual(relay.slots, [mac.deviceID])
    }

    func testTryAgainOpenRefusalsKeepTheLinkWaiting() async throws {
        let table: [(HostedRelayPairing.Refusal, PromotedLink.State)] = [
            (.slotsFull(macs: ["m1", "m2", "m3"]), .needsOwner(.slotsFull)),
            (.notPaying, .needsOwner(.notPaying)),
            (.unreachable, .needsOwner(.slotExpired))
        ]
        for (refusal, expected) in table {
            try await setUp()
            try seedPromoted(relayCode(), state: .needsOwner(.slotExpired))
            relay.fail("open", with: refusal)
            await makeModel().tryAgain(hub)
            XCTAssertEqual(state(), expected, "\(refusal)")
            XCTAssertTrue(host.pairZones.isEmpty, "never a hello")
            XCTAssertEqual(relay.count("vouch"), 0)
        }
    }

    func testPromoteSentAndNeedsOwnerResumeAtLaunchAndForeground() async throws {
        try seedPromoted(relayCode(), state: .promoteSent, vouchedAgo: 10)
        try seedPromoted(relayCode(otherHub, macName: "Home Mac", by: otherMac), state: .needsOwner(.notPaying))
        relay.fail("accountState", with: URLError(.timedOut))
        let model = makeModel()

        await model.resumePromotedLinks()  // launch
        XCTAssertEqual(state(), .promoteSent)
        clock.advance(by: PromotedLinkResumer.firstPause + 1)
        await model.resumePromotedLinks()  // foreground

        XCTAssertNil(state(), "the promoteSent link finished on the foreground")
        XCTAssertEqual(state(otherHub), .needsOwner(.notPaying), "the needs-owner link waits for the owner")
        XCTAssertFalse(relay.ops.contains("vouch \(otherMac.deviceID)"))
    }

    // MARK: - Scans while a link is promoted

    func testScanningTheSameHubResumesItsPromotedLink() async throws {
        try seedPromoted(relayCode(), state: .promoted)
        clock.advance(by: 3_600)
        let model = makeModel()

        await model.open(relayCode(issuedAgo: 3_600).url())

        XCTAssertEqual(model.phase, .linked(macName: "build-box"))
        XCTAssertTrue(relay.ops.isEmpty, "no open_pairing, no relay call")
        XCTAssertTrue(host.pairZones.isEmpty, "no hello")
    }

    func testScanningTheSameHubWhileNeedsOwnerReusesTheRecord() async throws {
        try seedPromoted(relayCode(), state: .needsOwner(.slotExpired))
        let model = makeModel()

        await model.open(relayCode().url())

        XCTAssertEqual(model.phase, .linked(macName: "build-box"))
        XCTAssertEqual(relay.ops, ["accountState", "open \(mac.deviceID)", "vouch \(mac.deviceID)", "promote slot-1"])
        XCTAssertTrue(host.pairZones.isEmpty, "no second hello")
    }

    func testNoStateEverWritesASecondHello() async throws {
        let states: [PromotedLink.State] = [.confirmed, .promoteSent, .promoted] + PromotedLink.Reason.allCases.map { .needsOwner($0) }
        for state in states {
            for viaScan in [false, true] {
                try await setUp()
                try seedPromoted(relayCode(), state: state, expiresIn: -1)
                let model = makeModel()
                if viaScan {
                    await model.open(relayCode().url())
                } else {
                    await model.tryAgain(hub)
                }
                XCTAssertTrue(host.pairZones.isEmpty, "\(state) via \(viaScan ? "scan" : "Try Again"): no hello")
            }
        }
    }

    func testOnlyCancelDeletesTheKeysOfAConfirmedLink() async throws {
        let refusals: [any Error] = [
            HostedRelayPairing.Refusal.pairingExpired, HostedRelayPairing.Refusal.slotsFull(macs: []),
            HostedRelayPairing.Refusal.notPaying, HostedRelayPairing.Refusal.unreachable,
            HostedRelayError.server(code: .notFound, retryAfter: nil), HostedRelayError.server(code: .forbidden, retryAfter: nil)
        ]
        for state in [PromotedLink.State.confirmed, .promoteSent, .needsOwner(.notConfirmed)] {
            for refusal in refusals {
                try await setUp()
                try seedPromoted(relayCode(), state: state, vouchedAgo: 10)
                relay.fail("promote", with: refusal)
                relay.fail("open", with: refusal)
                let model = makeModel()
                await model.resumePromotedLinks()
                await model.tryAgain(hub)
                XCTAssertTrue(try keysHeld(), "\(state) \(refusal)")
                if store.promoted[hub] != nil {
                    await model.cancelPromoted(hub)
                    XCTAssertFalse(try keysHeld(), "Cancel deletes them")
                }
            }
        }
    }

    func testScanningAnotherHubLinksNormallyWhileOneIsPromoted() async throws {
        try seedPromoted(relayCode(), state: .needsOwner(.notPaying))
        let iCloud = mac.code(hubID: otherHub, macName: "Work Mac", owner: owner, now: clock.now(), transport: nil)
        let viaRelay = relayCode(thirdHub, macName: "Home Mac", by: otherMac)
        macLinks([iCloud, viaRelay])
        let model = makeModel()

        await model.open(iCloud.url())
        XCTAssertEqual(model.phase, .linked(macName: "Work Mac"))
        await model.finish()
        await model.open(viaRelay.url())
        XCTAssertEqual(model.phase, .linked(macName: "Home Mac"))

        XCTAssertEqual(Set(model.links.map(\.hubID)), [otherHub, thirdHub])
        XCTAssertEqual(state(), .needsOwner(.notPaying), "the first row stays")
    }

    func testScanAnotherHubWhilePromoteSent() async throws {
        try seedPromoted(relayCode(), state: .promoteSent)
        let other = relayCode(otherHub, macName: "Home Mac", by: otherMac)
        macLinks(other)
        let model = makeModel()
        await model.open(other.url())
        XCTAssertEqual(model.phase, .linked(macName: "Home Mac"))
        XCTAssertEqual(state(), .promoteSent)
    }

    func testScanAnotherHubWhileNeedsOwner() async throws {
        try seedPromoted(relayCode(), state: .needsOwner(.slotsFull))
        let other = relayCode(otherHub, macName: "Home Mac", by: otherMac)
        macLinks(other)
        let model = makeModel()
        await model.open(other.url())
        XCTAssertEqual(model.phase, .linked(macName: "Home Mac"))
        XCTAssertEqual(state(), .needsOwner(.slotsFull))
    }

    func testAPromotedLinkCountsTowardTheFourMacs() async throws {
        for index in 0..<3 {
            seedRelayRow("AAAA000\(index)-0000-4000-8000-000000000001", macName: "Mac \(index)", relayMac: RelayTestMac(seed: UInt8(20 + index)))
        }
        try seedPromoted(relayCode(), state: .confirmed)
        let model = makeModel()

        await model.open(relayCode(otherHub, macName: "Fifth", by: otherMac).url())

        XCTAssertEqual(model.phase, .failed(.tooManyMacs))
    }

    // MARK: - Cancel and slot removals

    func testCancellingAPromotedLinkSendsTheFarewellThenRemovesTheSlot() async throws {
        try seedPromoted(relayCode(), state: .needsOwner(.notPaying))
        relay.slots = [mac.deviceID]
        host.resendSucceeds = true
        let model = makeModel()

        await model.cancelPromoted(hub)

        XCTAssertEqual(Array(log.events.prefix(3)), ["seal farewell \(hub)", "keep farewell \(hub)", "resend \(hub)"])
        XCTAssertEqual(relay.ops, ["removeSlot \(mac.deviceID)"])
        XCTAssertTrue(relay.slots.isEmpty)
        XCTAssertEqual(host.removedHubIDs, [hub])
        XCTAssertFalse(try keysHeld())
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertTrue(host.keptFarewells.isEmpty, "sent")
    }

    func testCancelFarewellFailsRemoveSlotSucceeds() async throws {
        try seedPromoted(relayCode(), state: .promoted)
        host.resendSucceeds = false
        relay.slots = [mac.deviceID]
        let model = makeModel()

        await model.cancelPromoted(hub)

        XCTAssertTrue(relay.slots.isEmpty, "the slot is freed")
        XCTAssertTrue(host.keptFarewells.isEmpty, "the kept farewell is undeliverable once the slot is free")
        XCTAssertTrue(log.events.contains("drop farewell \(hub)"))
        XCTAssertFalse(try keysHeld())
        XCTAssertEqual(host.removedHubIDs, [hub])
        XCTAssertTrue(host.slotRemovals.isEmpty)
    }

    func testCancelBothFailKeepsTheSlotRemovalForLaunch() async throws {
        try seedPromoted(relayCode(), state: .promoted)
        host.resendSucceeds = false
        relay.slots = [mac.deviceID]
        relay.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        let model = makeModel()

        await model.cancelPromoted(hub)

        XCTAssertFalse(try keysHeld(), "local state goes either way")
        XCTAssertTrue(store.promoted.isEmpty)
        XCTAssertEqual(host.slotRemovals, [mac.deviceID])
        XCTAssertEqual(host.keptFarewells.map(\.route), [.hostedRelay(macDeviceID: mac.deviceID)])

        // The next launch: the farewell first, then the slot.
        host.resendSucceeds = true
        let relaunched = makeModel()
        await relaunched.retryFarewells()
        XCTAssertTrue(host.keptFarewells.isEmpty)
        XCTAssertEqual(relay.count("removeSlot"), 1, "not yet")
        await relaunched.retrySlotRemovals()
        XCTAssertEqual(relay.count("removeSlot"), 2)
        XCTAssertTrue(relay.slots.isEmpty)
        XCTAssertTrue(host.slotRemovals.isEmpty)
    }

    /// Carry-over 1 (R19): a relay farewell needs no iCloud account and survives an account change.
    func testARelayFarewellSurvivesAnAccountChange() async throws {
        try seedPromoted(relayCode(), state: .promoted)
        host.resendSucceeds = false
        relay.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        await makeModel().cancelPromoted(hub)
        XCTAssertEqual(host.keptFarewells.count, 1)

        container.status = .noAccount
        await makeModel().retryFarewells()
        XCTAssertEqual(host.keptFarewells.count, 1, "kept while unsent")
        XCTAssertTrue(log.events.filter { $0 == "resend \(hub)" }.count >= 2, "sent again with no iCloud account")

        container.status = .available
        container.userRecordNameValue = "_someone-else"
        host.resendSucceeds = true
        await makeModel().retryFarewells()
        XCTAssertTrue(host.keptFarewells.isEmpty, "sent, never dropped for the account")
        XCTAssertFalse(log.events.contains("drop farewell \(hub)"))
    }

    func testARelinkOfTheSameMacCancelsItsPendingSlotRemoval() async throws {
        host.slotRemovals = [mac.deviceID]
        let model = makeModel()

        await link(relayCode(), model: model)

        XCTAssertTrue(host.slotRemovals.isEmpty, "the confirmed write dropped it")
        await model.retrySlotRemovals()
        XCTAssertEqual(relay.count("removeSlot"), 0)
    }

    func testASlotRemovalIsNeverRetriedForAMacALocalLinkNames() async throws {
        // A promoted link in promoteSent or needsOwner, or a pending link, names the Mac.
        for state in [PromotedLink.State.promoteSent, .needsOwner(.slotsFull)] {
            try await setUp()
            try seedPromoted(relayCode(), state: state)
            host.slotRemovals = [mac.deviceID]
            await makeModel().retrySlotRemovals()
            XCTAssertTrue(host.slotRemovals.isEmpty, "\(state): the row is deleted")
            XCTAssertEqual(relay.count("removeSlot"), 0)
        }
        try await setUp()
        clock.parked = true
        let model = makeModel()
        let flow = Task { await model.open(relayCode().url()) }
        try await poll { model.phase == .waiting(macName: "build-box") }
        host.slotRemovals = [mac.deviceID]
        flow.cancel()
        await flow.value
        await makeModel().retrySlotRemovals()
        XCTAssertTrue(host.slotRemovals.isEmpty)
        XCTAssertEqual(relay.count("removeSlot"), 0, "the pending link names the Mac")
    }

    func testUnlinkingARelayHubSendsTheFarewellThenRemovesTheSlot() async throws {
        seedRelayRow(hub, macName: "build-box", relayMac: mac)
        relay.slots = [mac.deviceID]
        let model = makeModel()
        model.refreshLinks()

        await model.unlink(hub)

        XCTAssertEqual(host.farewells.map(\.route), [.hostedRelay(macDeviceID: mac.deviceID)])
        XCTAssertEqual(relay.ops, ["removeSlot \(mac.deviceID)"])
        XCTAssertTrue(relay.slots.isEmpty)
        XCTAssertTrue(container.left.isEmpty, "a Relay link has no shares to leave")
    }

    func testASlotRemovalThatFailedIsRetriedAtLaunch() async throws {
        seedRelayRow(hub, macName: "build-box", relayMac: mac)
        relay.slots = [mac.deviceID]
        relay.fail("removeSlot", with: HostedRelayPairing.Refusal.unreachable)
        let model = makeModel()
        model.refreshLinks()
        await model.unlink(hub)
        XCTAssertEqual(host.slotRemovals, [mac.deviceID])

        await makeModel().retrySlotRemovals()

        XCTAssertTrue(host.slotRemovals.isEmpty)
        XCTAssertTrue(relay.slots.isEmpty)
    }

    func testAPromotedMacIsNamedOnTheSlotsScreenAndItsRemoveCancels() async throws {
        let finishing = RelayTestMac(seed: 11)
        try seedPromoted(relayCode(otherHub, macName: "build-box", by: finishing), state: .needsOwner(.notPaying))
        relay.slots = [finishing.deviceID, "m2", "m3"]
        let payload = relayCode(hub, macName: "Work Mac", cloudKit: true)
        macLinks(payload)
        let model = makeModel()
        await model.open(payload.url())

        let screen = RelaySlotsModel(state: model.relaySlots, links: model.links, promoted: model.promotedLinks)
        let row = try XCTUnwrap(screen.rows.first)
        XCTAssertEqual(row.name, "build-box")
        XCTAssertEqual(row.sub, "Finishing link")
        let ask = try XCTUnwrap(RelaySlotsModel.ask(for: row))
        XCTAssertEqual(ask.title, "Cancel the link to build-box? It frees its Relay slot.")
        XCTAssertEqual([ask.confirm, ask.keep], ["Cancel Link", "Keep Trying"])

        await model.removeFromSlots(finishing.deviceID)

        XCTAssertTrue(log.events.contains("seal farewell \(otherHub)"), "the farewell attempt")
        XCTAssertTrue(relay.ops.contains("removeSlot \(finishing.deviceID)"))
        XCTAssertNil(state(otherHub))
        XCTAssertFalse(try keysHeld(otherHub))
        XCTAssertEqual(model.phase, .linked(macName: "Work Mac"))
    }

    func testManageMacsAfterConfirmationContinuesTheLinkAfterARemoval() async throws {
        try seedPromoted(relayCode(), state: .needsOwner(.slotsFull), vouchedAgo: 10)
        relay.slots = ["m1", "m2", "m3"]
        let model = makeModel()
        let row = try XCTUnwrap(MacsModel.finishingRows(model.promotedLinks, running: [], failed: []).first)
        XCTAssertEqual(row.actions.map(\.title), ["Manage Macs", "Try Again", "Cancel"])

        await model.manageSlots(for: hub)
        XCTAssertEqual(model.relaySlots.macs, ["m1", "m2", "m3"])
        await model.removeFromSlots("m2")

        XCTAssertTrue(store.promoted.isEmpty, "the confirmed link went on: vouch, promote, linked")
        XCTAssertEqual(relay.count("open"), 0, "its slot was still open")
        XCTAssertEqual(model.relaySlots, RelaySlotsState(), "the screen closed")
    }

    // MARK: - Not a reader yet

    func testForbiddenBeforeTheFirstReadIsRetriedAndNeverARemoval() async throws {
        let model = makeModel()
        await link(relayCode(), model: model)
        await model.finish()

        // Before the hub names the phone in its readers no grant or heartbeat reaches the replica: nothing is judged.
        await model.evaluate(hubID: hub, grant: nil, heartbeat: nil)
        await model.hubRunsOnRelay(hub)

        XCTAssertTrue(host.markedRemoved.isEmpty)
        XCTAssertTrue(host.removedHubIDs.isEmpty)
        XCTAssertEqual(model.links.map(\.hubID), [hub])
    }

    // MARK: - A Mac on Relay over iCloud

    func testAnICloudLinkToAMacOnRelayEndsWithMacOnRelay() async throws {
        let payload = mac.code(hubID: hub, macName: "Work Mac", owner: owner, now: clock.now(), transport: nil)
        macLinks(payload)
        host.onRelay = [hub]
        let model = makeModel(relay: OffRelayLinkOps())

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.macOnRelay(macName: "Work Mac")))
        XCTAssertEqual(LinkFailure.macOnRelay(macName: "Work Mac").title, "Work Mac runs over Relay")
        XCTAssertTrue(model.links.isEmpty, "no row left")
        XCTAssertEqual(host.farewells.map(\.hubID), [hub], "the unlinked farewell, best effort")
        XCTAssertFalse(try keysHeld())
    }

    func testANeverLiveLinkThatGetsHubOnRelayEnds() async throws {
        let payload = mac.code(hubID: hub, macName: "Work Mac", owner: owner, now: clock.now(), transport: nil)
        macLinks(payload)
        let model = makeModel(relay: OffRelayLinkOps())
        await model.open(payload.url())
        await model.finish()
        XCTAssertEqual(model.links.count, 1)

        await model.hubRunsOnRelay(hub)

        XCTAssertTrue(model.links.isEmpty)
        XCTAssertEqual(model.notice, .macOnRelay(macName: "Work Mac"))
        XCTAssertEqual(
            model.notice?.message,
            "Work Mac runs over Relay — This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud."
        )
    }

    func testALiveLinkThatGetsHubOnRelayIsKept() async throws {
        let payload = mac.code(hubID: hub, macName: "Work Mac", owner: owner, now: clock.now(), transport: nil)
        macLinks(payload)
        let model = makeModel(relay: OffRelayLinkOps())
        await model.open(payload.url())
        await model.finish()
        host.noteHeartbeat(clock.now().addingTimeInterval(60), hubID: hub)

        await model.hubRunsOnRelay(hub)

        XCTAssertEqual(model.links.map(\.hubID), [hub], "the Mac can switch back")
        XCTAssertNil(model.notice)
    }

    func testAPayingPhoneNeverEndsAnICloudLinkThisWay() async throws {
        let payload = mac.code(hubID: hub, macName: "Work Mac", owner: owner, now: clock.now(), transport: nil)
        macLinks(payload)
        host.onRelay = [hub]
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Work Mac"), "it follows the switch instead (Task 11)")
    }
}

/// Both lanes on one zone, as a Relay link's pairing transport maps them to `pair/<slot>`: every save lands in the
/// inner transport's data zone, and either lane reads it.
private actor PairZoneTransport: CloudSyncTransport {
    let inner: InMemoryCloudTransport

    init(inner: InMemoryCloudTransport) {
        self.inner = inner
    }

    func save(_ records: [CloudRecord]) async throws {
        try await inner.save(records.map {
            CloudRecord(recordName: $0.recordName, zone: .data, kind: $0.kind, modifiedAt: $0.modifiedAt, payload: $0.payload)
        })
    }

    func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try await inner.delete(recordNames: recordNames, in: .data)
    }

    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try await inner.changes(in: .data, since: token)
    }
}

/// Carry-over 4 (Task 5 review): a pairing-mode session reads the pair zone on both lanes. It applies the hub's
/// keybox once and treats its own hello, which it reads back on both lanes, as nothing.
@MainActor
final class PairingSessionTests: XCTestCase {
    func testAPairingSessionAppliesTheKeyboxOnceAndIgnoresItsOwnHello() async throws {
        let inner = InMemoryCloudTransport()
        let sleeper = TickSleeper()
        let session = try HubSession(
            transport: PairZoneTransport(inner: inner),
            replicaPath: try makeReplicaPath(),
            backend: .live,
            hubID: TestE2E.hubID.uuidString,
            keys: try TestPhone.keys(),
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            notifications: NotificationCenter(),
            sleep: { try await sleeper.sleep($0) } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in session.stop() }
        try await poll { session.isLooping && sleeper.waitingCount == 1 }
        var signals = 0
        session.onKeyboxChanged = { signals += 1 }

        let device = DevicePayload(
            deviceID: TestE2E.deviceID.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0",
            scope: .private, userRecordName: "", linkNonce: "nonce", unlinked: nil, typingRequested: false,
            startSessions: true, updatedAt: Date()
        )
        let hello = DeviceHello(device: device, signingKey: "s", agreementKey: "a", relayDeviceID: FakeRelayOps.phoneID)
        try await session.linkTransport.save([try CloudRecordFactory.record(for: hello, modifiedAt: Date())])
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: TestE2E.hubID.uuidString, name: "Colleague A's iPhone",
            scope: .private, linked: true, typingAllowed: false, startSessionsAllowed: true
        )
        try await TestPhone.hub(over: inner).save([try TestPhone.grantRecord(grant, keys: TestPhone.keyboxKeys(), modifiedAt: Date())])

        _ = await session.refresh(.pull)
        _ = await session.refresh(.pull)

        XCTAssertEqual(signals, 1, "the keybox is applied once")
        let keybox = try XCTUnwrap(try session.keybox(deviceID: TestE2E.deviceID))
        XCTAssertTrue(keybox.grant.linked)
        let rows = try await session.store.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM slice_records") ?? 0 }
        XCTAssertEqual(rows, 1, "the phone's own hello is no row")
        let pending = try await session.store.pendingActions()
        XCTAssertTrue(pending.isEmpty, "and nothing to send")
    }

    /// R4: the hub's transport marker in its data zone (plain kind `transport`, id `marker`) with `target: relay`
    /// tells the link flow the hub runs over Relay; `cloudkit` does not.
    func testTheTransportMarkerSaysWhetherTheHubRunsOverRelay() async throws {
        let inner = InMemoryCloudTransport()
        let sleeper = TickSleeper()
        let session = try HubSession(
            transport: inner,
            replicaPath: try makeReplicaPath(),
            backend: .live,
            hubID: TestE2E.hubID.uuidString,
            keys: try TestPhone.keys(),
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            notifications: NotificationCenter(),
            sleep: { try await sleeper.sleep($0) } // swiftlint:disable:this trailing_closure
        )
        addTeardownBlock { @MainActor in session.stop() }
        try await poll { session.isLooping && sleeper.waitingCount == 1 }
        XCTAssertFalse(session.runsOnRelay())

        func marker(_ target: String, at date: Date) -> CloudRecord {
            CloudRecord(
                recordName: HubSession.transportMarkerName, zone: .data, kind: "transport", modifiedAt: date,
                payload: Data(#"{"target":"\#(target)","epoch":2,"by":"phone","at":1800000000}"#.utf8)
            )
        }
        // The Swift test hub does not seal kind `transport` (only the Go hub writes it): sealed directly.
        try await inner.save([try TestE2E.sealedDataRecord(marker("cloudkit", at: Date()), seq: 100)])
        _ = await session.refresh(.pull)
        XCTAssertFalse(session.runsOnRelay(), "a hub back on iCloud")

        try await inner.save([try TestE2E.sealedDataRecord(marker("relay", at: Date().addingTimeInterval(1)), seq: 101)])
        _ = await session.refresh(.pull)
        XCTAssertTrue(session.runsOnRelay())
    }
}
