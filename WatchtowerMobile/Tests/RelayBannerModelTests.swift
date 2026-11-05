import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Now's Relay banners (relay client Phase 4 Task 10, mockup S30–S36, S47, S50, S51, S53): one at most, first match wins,
/// with the mockup's exact texts.
@MainActor
final class RelayBannerModelTests: XCTestCase {
    /// Pinned at local noon today, so 10:41 is today's clock.
    private let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()
    private let relayRoute = HubRoute.hostedRelay(macDeviceID: "mac")
    private let iCloudRoute = HubRoute.cloudKit(.private)

    private var tenFortyOne: Date {
        Calendar.current.date(bySettingHour: 10, minute: 41, second: 0, of: now) ?? now
    }

    private func available() throws -> RelayAvailability {
        .available(try RelayOrigin("https://relay.example.com"))
    }

    private func banner(
        availability: RelayAvailability? = nil,
        phase: RelayAccountCenter.Phase = .free(ended: false),
        unconfirmed: Bool = false,
        updateRequired: Bool = false,
        wasPaying: Bool = false,
        route: HubRoute? = .cloudKit(.private),
        relayOnly: Bool = false,
        hubOnRelayAt: Date? = nil,
        unansweredFor: TimeInterval? = nil,
        request: TransportRequestRecord? = nil,
        pressRefusal: TransportRequestRefusal? = nil,
        lastUpdate: Date? = nil,
        macName: String = "Work Mac"
    ) throws -> RelayBannerModel? {
        RelayBannerModel.banner(
            availability: try availability ?? available(), phase: phase, unconfirmedPurchase: unconfirmed,
            updateRequired: updateRequired, wasPaying: wasPaying, route: route, relayOnly: relayOnly,
            hubOnRelayAt: hubOnRelayAt, unansweredSince: unansweredFor.map { now.addingTimeInterval(-$0) },
            request: request, pressRefusal: pressRefusal, lastUpdate: lastUpdate, macName: macName, now: now
        )
    }

    private func request(refusal: TransportRequestRefusal? = nil, reason: String? = nil) -> TransportRequestRecord {
        TransportRequestRecord(target: .cloudKit, controlID: "c", reason: reason, at: now, refusal: refusal)
    }

    private let outage = "Relay unavailable for 12 min. Your changes wait on this iPhone."
    private let s30 = "Work Mac runs over Relay. This iPhone doesn't get updates from it. "
        + "Subscribe or switch the Mac to iCloud from a subscribed phone."
    private let s51 = "Work Mac runs over Relay. This iPhone doesn't get updates from it. "
        + "Switch the Mac to iCloud from a subscribed phone."

    // MARK: - The table

    func testBannerTable() throws {
        let s35 = try XCTUnwrap(try banner(updateRequired: true, wasPaying: true))
        XCTAssertEqual(s35.text, "Update Watchtower from the App Store to keep using Relay.")
        XCTAssertEqual(s35.actions, [])
        XCTAssertEqual(
            try banner(updateRequired: true)?.text, "Update Watchtower from the App Store to use Relay.",
            "a phone that never paid has nothing to keep (S43's words)"
        )

        let s47 = try XCTUnwrap(try banner(phase: .free(ended: true), route: relayRoute, relayOnly: true, macName: "build-box"))
        XCTAssertEqual(s47.text, "build-box needs Relay. Your subscription ended.")
        XCTAssertEqual(s47.actions, [.subscribe])

        let s53 = try XCTUnwrap(try banner(phase: .moved, route: relayRoute, relayOnly: true, macName: "build-box"))
        XCTAssertEqual(s53.text, "build-box needs Relay. Your subscription moved to another iPhone.")
        XCTAssertEqual(s53.actions, [.restore])

        let s33 = try XCTUnwrap(try banner(phase: .moved, wasPaying: true))
        XCTAssertEqual(s33.text, "Your Relay subscription moved to another iPhone. This iPhone is back on iCloud.")
        XCTAssertEqual(s33.actions, [.restore, .ok])

        let s34 = try XCTUnwrap(try banner(phase: .free(ended: true), wasPaying: true))
        XCTAssertEqual(s34.text, "Your Relay subscription ended. This iPhone is back on iCloud.")
        XCTAssertEqual(s34.actions, [.subscribe, .ok])

        let s30 = try XCTUnwrap(try banner(hubOnRelayAt: now, lastUpdate: tenFortyOne))
        XCTAssertEqual(s30.text, self.s30)
        XCTAssertEqual(s30.secondLine, "Last update from Work Mac: 10:41")
        XCTAssertEqual(s30.actions, [.subscribe])

        let s31 = try XCTUnwrap(try banner(phase: .paying(grace: false, macs: []), route: relayRoute, unansweredFor: 3 * 60))
        XCTAssertEqual(s31.text, "Relay unavailable for 3 min. Your changes wait on this iPhone.")
        XCTAssertNil(s31.secondLine)
        XCTAssertEqual(s31.actions, [])

        let s32 = try XCTUnwrap(try banner(phase: .paying(grace: false, macs: []), route: relayRoute, unansweredFor: 12 * 60))
        XCTAssertEqual(s32.text, outage)
        XCTAssertEqual(s32.actions, [.switchToICloud])
        XCTAssertEqual(s32.title(for: .switchToICloud), "Switch Work Mac to iCloud")

        let s36 = try XCTUnwrap(try banner(
            phase: .paying(grace: false, macs: []), route: relayRoute, unansweredFor: 12 * 60, request: request()
        ))
        XCTAssertEqual(s36.text, outage)
        XCTAssertEqual(s36.secondLine, "Switching to iCloud…")
        XCTAssertTrue(s36.busy)
        XCTAssertEqual(s36.actions, [])

        XCTAssertNil(try banner(), "a free phone on iCloud: nothing to say")
        XCTAssertNil(try banner(phase: .paying(grace: false, macs: ["a"]), wasPaying: true))
    }

    func testActionTitles() throws {
        let model = try XCTUnwrap(try banner(phase: .moved, wasPaying: true))
        XCTAssertEqual(model.title(for: .restore), "Restore Purchases")
        XCTAssertEqual(model.title(for: .ok), "OK")
        XCTAssertEqual(model.title(for: .subscribe), "Subscribe")
        XCTAssertEqual(model.title(for: .confirmPurchase), "Your purchase isn't confirmed yet.")
        XCTAssertEqual(RelayBannerModel.sheetClose, "Close")
    }

    func testTheFirstMatchWins() throws {
        // Everything holds at once: each row gives way only when the one above it stops holding.
        let all = (phase: RelayAccountCenter.Phase.moved, at: now)
        let update = try XCTUnwrap(try banner(
            phase: all.phase, updateRequired: true, wasPaying: true, route: relayRoute, relayOnly: true,
            hubOnRelayAt: all.at, unansweredFor: 3_600
        ))
        XCTAssertEqual(update.text, "Update Watchtower from the App Store to keep using Relay.")
        let needs = try XCTUnwrap(try banner(
            phase: all.phase, wasPaying: true, route: relayRoute, relayOnly: true, hubOnRelayAt: all.at, unansweredFor: 3_600
        ))
        XCTAssertEqual(needs.text, "Work Mac needs Relay. Your subscription moved to another iPhone.")
        let moved = try XCTUnwrap(try banner(phase: all.phase, wasPaying: true, hubOnRelayAt: all.at))
        XCTAssertEqual(moved.text, "Your Relay subscription moved to another iPhone. This iPhone is back on iCloud.")
        let ended = try XCTUnwrap(try banner(phase: .free(ended: true), wasPaying: true, hubOnRelayAt: all.at))
        XCTAssertEqual(ended.text, "Your Relay subscription ended. This iPhone is back on iCloud.")
        let free = try XCTUnwrap(try banner(phase: .free(ended: true), route: relayRoute, hubOnRelayAt: all.at, unansweredFor: 3_600))
        XCTAssertEqual(free.text, s30)
    }

    // MARK: - Relay unavailable

    func testUnavailableStartsAtSixtySeconds() throws {
        XCTAssertNil(try banner(route: relayRoute, unansweredFor: 59))
        XCTAssertEqual(
            try banner(route: relayRoute, unansweredFor: 60)?.text, "Relay unavailable for 1 min. Your changes wait on this iPhone.")
        XCTAssertEqual(
            try banner(route: relayRoute, unansweredFor: 119)?.text, "Relay unavailable for 1 min. Your changes wait on this iPhone.")
        XCTAssertEqual(
            try banner(route: relayRoute, unansweredFor: 120)?.text, "Relay unavailable for 2 min. Your changes wait on this iPhone.")
        XCTAssertNil(try banner(route: iCloudRoute, unansweredFor: 3_600), "only a relay route has an outage")
        XCTAssertNil(try banner(route: nil, unansweredFor: 3_600))
    }

    func testTheOfferStartsAtTenMinutes() throws {
        XCTAssertEqual(try banner(route: relayRoute, unansweredFor: 599)?.actions, [])
        XCTAssertEqual(try banner(route: relayRoute, unansweredFor: 600)?.actions, [.switchToICloud])
    }

    func testARelayOnlyHubIsNeverOfferedICloud() throws {
        let model = try XCTUnwrap(try banner(
            phase: .paying(grace: false, macs: []), route: relayRoute, relayOnly: true, unansweredFor: 3_600
        ))
        XCTAssertEqual(model.text, "Relay unavailable for 60 min. Your changes wait on this iPhone.")
        XCTAssertEqual(model.actions, [])
        let refused = try XCTUnwrap(try banner(
            phase: .paying(grace: false, macs: []), route: relayRoute, relayOnly: true, unansweredFor: 3_600,
            request: request(refusal: .notSupported)
        ))
        XCTAssertEqual(refused.actions, [])
    }

    func testTheBannerNeverSwitchesByItself() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        bed.fake.crash()
        await bed.fetch(session)
        let since = try XCTUnwrap(session.relayUnansweredSince, "the outage started")
        bed.clock.advance(3_600)
        await bed.fetch(session)
        XCTAssertEqual(session.relayUnansweredSince, since)

        let offer = try XCTUnwrap(RelayBannerModel.banner(
            availability: try available(), phase: .paying(grace: false, macs: []), unconfirmedPurchase: false, updateRequired: false,
            wasPaying: true, route: session.route, relayOnly: false, hubOnRelayAt: session.hubOnRelayAt,
            unansweredSince: session.relayUnansweredSince, request: session.transportRequest, pressRefusal: nil,
            lastUpdate: nil, macName: "Work Mac", now: bed.clock.now
        ))
        XCTAssertEqual(offer.actions, [.switchToICloud], "an hour in, it offers")
        XCTAssertNil(try bed.row()?.link.transportRequest, "and has asked nothing")
        let controls = try await bed.cloudControls(.transportSwitch)
        XCTAssertEqual(controls.count, 0)
    }

    func testAPressShowsBusyAndStaysUntilTheMove() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let press = RelayBannerPress.run(.switchToICloud, session: session, center: nil) {}
        _ = await press?.value
        await session.outbox.drain()
        let open = try XCTUnwrap(session.transportRequest)
        XCTAssertTrue(open.isOpen)

        func model(route: HubRoute?, request: TransportRequestRecord?) throws -> RelayBannerModel? {
            try banner(phase: .paying(grace: false, macs: []), route: route, unansweredFor: 12 * 60, request: request)
        }
        let busy = try XCTUnwrap(try model(route: session.route, request: open))
        XCTAssertTrue(busy.busy)
        XCTAssertEqual(busy.secondLine, "Switching to iCloud…")
        XCTAssertEqual(busy.actions, [], "a second press has nothing to press")
        XCTAssertEqual(try model(route: session.route, request: open), busy, "a closed Mac: the request waits and the banner stays")

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        let moved = try await bed.fetchAndFollow(session)
        XCTAssertNil(try model(route: moved.route, request: moved.transportRequest), "the move ends it")
    }

    func testAPressAsksWithTheCentersReason() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let center = RelayAccountCenter(
            link: RelayAccountLink(hasIdentity: { false }, account: { nil }, events: { nil }),
            store: FakeSubscriptionStore(), defaults: try XCTUnwrap(UserDefaults(suiteName: "relay-banner-\(UUID().uuidString)"))
        ) { [] }
        center.start()
        XCTAssertEqual(center.phase, .free(ended: false))

        let press = try XCTUnwrap(RelayBannerPress.run(.switchToICloud, session: session, center: center) {})
        let refusal = await press.value
        XCTAssertNil(refusal, "written: the row speaks from here")
        XCTAssertEqual(session.transportRequest?.reason, TransportFollowerPolicy.lapseReason)
    }

    func testAPressWithNoOrderedPathReportsWhatTheRowCannot() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try bed.session()
        await session.waitForBoot()
        let press = try XCTUnwrap(RelayBannerPress.run(.switchToICloud, session: session, center: nil) {})
        let refusal = await press.value
        XCTAssertEqual(refusal, .notOrdered)
        XCTAssertNil(session.transportRequest, "nothing was written")
    }

    /// A failed write on a hub still on the relay: the press must not look dead.
    func testAPressReturnsAnyRefusal() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        try failingRowWrites(bed, session)

        let press = try XCTUnwrap(RelayBannerPress.run(.switchToICloud, session: session, center: nil) {})
        let refusal = await press.value

        XCTAssertEqual(refusal, .unavailable)
        XCTAssertNil(try bed.row()?.link.transportRequest, "nothing was written")
        let model = try XCTUnwrap(try banner(route: session.route, unansweredFor: 12 * 60, pressRefusal: refusal))
        XCTAssertEqual(model.secondLine, TransportRequestRefusal.unavailable.message(macName: "Work Mac"))
        XCTAssertEqual(model.actions, [.switchToICloud])
    }

    /// The Connection section's press, on the same failure: the line and Try Again come back, and Try Again asks again.
    func testAConnectionPressReturnsAnyRefusal() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let host = try failingRowWrites(bed, session)

        let refusal = await MacTransportPress.run(.chooseICloud, session: session, center: nil)
        XCTAssertEqual(refusal, .unavailable)
        XCTAssertNil(try bed.row()?.link.transportRequest)

        let link = try XCTUnwrap(try bed.row()?.link)
        var facts = SessionTransportFacts(link: link, store: session.store, now: now)
        facts.pressRefusal = refusal
        let model = MacTransportModel(
            link: link, grant: nil, phase: .paying(grace: false, macs: []), unconfirmedPurchase: false, availability: try available(),
            session: facts, macName: "Work Mac", ownDeviceID: link.deviceID, now: now
        )
        let row = try XCTUnwrap(model.rows.first { $0.title == MacTransportModel.iCloudTitle })
        XCTAssertEqual(row.line, TransportRequestRefusal.unavailable.message(macName: "Work Mac"))
        XCTAssertEqual(row.action, .tryAgain)

        host.persistFails = false
        let again = await MacTransportPress.run(.tryAgain, session: session, center: nil)
        XCTAssertNil(again)
        XCTAssertEqual(try bed.row()?.link.transportRequest?.isOpen, true, "Try Again on the relay asks for iCloud, never an upgrade")
    }

    /// The session's request now writes through a host whose row writes fail.
    @discardableResult
    private func failingRowWrites(_ bed: Bed, _ session: HubSession) throws -> RowWriteFailingHost {
        let host = RowWriteFailingHost(root: bed.root)
        let follower = TransportFollower(hubID: session.hubID, outbox: session.outbox, host: bed.root)
        session.attach(TransportRequester(session: session, follower: follower, host: host) { [clock = bed.clock] in clock.now })
        return host
    }

    func testARefusedRequestAsksAgainWithItsOwnReason() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let first = RelayBannerPress.run(.switchToICloud, session: session, center: nil) {}
        _ = await first?.value
        var link = try XCTUnwrap(try bed.row()?.link)
        var record = try XCTUnwrap(link.transportRequest)
        record = TransportRequestRecord(
            target: record.target, controlID: record.controlID, reason: TransportFollowerPolicy.lapseReason, at: record.at, refusal: .unavailable
        )
        link.transportRequest = record
        XCTAssertTrue(bed.root.persistRoute(link))

        let again = RelayBannerPress.run(.switchToICloud, session: session, center: nil) {}
        _ = await again?.value
        XCTAssertEqual(session.transportRequest?.reason, TransportFollowerPolicy.lapseReason, "Try Again keeps the record's reason")
        XCTAssertEqual(session.transportRequest?.isOpen, true)
    }

    // MARK: - A refused request

    func testARefusedRequestShowsItsLineAndTheActionAgain() throws {
        let unavailable = TransportRequestRefusal.unavailable.message(macName: "Work Mac")
        let s50 = try XCTUnwrap(try banner(
            route: relayRoute, unansweredFor: 12 * 60, request: request(refusal: .unavailable)
        ))
        XCTAssertEqual(s50.text, outage)
        XCTAssertEqual(s50.secondLine, unavailable)
        XCTAssertEqual(s50.secondLineTone, .red)
        XCTAssertEqual(s50.actions, [.switchToICloud])
        XCTAssertFalse(s50.busy)

        let noAnswer = try XCTUnwrap(try banner(
            route: relayRoute, unansweredFor: 12 * 60, request: request(refusal: .macNoAnswer)
        ))
        XCTAssertEqual(noAnswer.secondLine, "Work Mac didn't answer for a day, so nothing changed. Try again when it's back.")
        XCTAssertEqual(noAnswer.actions, [.switchToICloud])

        let early = try XCTUnwrap(try banner(route: relayRoute, unansweredFor: 60, request: request(refusal: .unavailable)))
        XCTAssertEqual(early.actions, [.switchToICloud], "after a relaunch the minutes restart, the way out does not")
    }

    func testALapsesKeptCopyPromisesTheMoveWithNothingToPress() throws {
        let model = try XCTUnwrap(try banner(
            phase: .unknown, route: relayRoute, unansweredFor: 12 * 60,
            request: request(refusal: .lapseNoAnswer, reason: TransportFollowerPolicy.lapseReason)
        ))
        XCTAssertEqual(model.secondLine, "Work Mac didn't answer for a day. It moves to iCloud when it's back.")
        XCTAssertEqual(model.secondLineTone, .secondary)
        XCTAssertEqual(model.actions, [])
    }

    func testAPressThatWroteNothingShowsWhy() throws {
        let model = try XCTUnwrap(try banner(route: relayRoute, unansweredFor: 12 * 60, pressRefusal: .notOrdered))
        XCTAssertEqual(model.secondLine, "Update Watchtower on Work Mac to change how it connects.")
        XCTAssertEqual(model.actions, [.switchToICloud])
    }

    func testAnOpenRequestStaysWhenTheRelayAnswers() throws {
        let model = try XCTUnwrap(try banner(
            phase: .paying(grace: false, macs: []), route: relayRoute, unansweredFor: nil, request: request()
        ))
        XCTAssertEqual(model.text, "Switching to iCloud…", "no outage to report: the press alone")
        XCTAssertNil(model.secondLine)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.actions, [])
        XCTAssertEqual(
            try banner(phase: .paying(grace: false, macs: []), route: relayRoute, unansweredFor: 30, request: request())?.text,
            "Switching to iCloud…", "under a minute of silence, after a relaunch"
        )
        XCTAssertNil(try banner(phase: .paying(grace: false, macs: []), route: iCloudRoute, request: request()), "the move ends it")
        XCTAssertNil(try banner(phase: .paying(grace: false, macs: []), route: relayRoute, request: request(refusal: .unavailable)))
    }

    // MARK: - The clock

    /// Only an outage's words change with time, and an outage shows only on a relay route that stopped answering.
    func testOnlyAnUnansweredRelayRouteRunsAClock() {
        XCTAssertFalse(RelayBannerModel.needsClock(route: iCloudRoute, unansweredSince: nil))
        XCTAssertFalse(RelayBannerModel.needsClock(route: iCloudRoute, unansweredSince: now), "an iCloud route has no outage")
        XCTAssertFalse(RelayBannerModel.needsClock(route: relayRoute, unansweredSince: nil))
        XCTAssertTrue(RelayBannerModel.needsClock(route: relayRoute, unansweredSince: now))
    }

    // MARK: - Dark

    func testAnEmptyOriginShowsOnlyTheMacOnRelayBanner() throws {
        let dark = RelayAvailability.off(.notConfigured)
        for phase in [RelayAccountCenter.Phase.checking, .unknown, .free(ended: true), .moved, .paying(grace: false, macs: [])] {
            XCTAssertNil(try banner(
                availability: dark, phase: phase, unconfirmed: true, updateRequired: true, wasPaying: true, route: relayRoute,
                relayOnly: true, unansweredFor: 3_600, request: request(refusal: .unavailable)
            ), "\(phase)")
            let s51 = try XCTUnwrap(try banner(
                availability: dark, phase: phase, unconfirmed: true, updateRequired: true, wasPaying: true,
                hubOnRelayAt: now, unansweredFor: 3_600, lastUpdate: tenFortyOne
            ), "\(phase)")
            XCTAssertEqual(s51.text, self.s51)
            XCTAssertEqual(s51.secondLine, "Last update from Work Mac: 10:41")
            XCTAssertEqual(s51.actions, [])
        }
        let attest = try XCTUnwrap(try banner(availability: .off(.unsupportedDevice), hubOnRelayAt: now))
        XCTAssertEqual(attest.text, s51)
    }

    // MARK: - Moved and ended

    func testANeverPayingPhoneHasNoEndedBanner() throws {
        XCTAssertNil(try banner(phase: .free(ended: true), wasPaying: false))
        XCTAssertNil(try banner(phase: .moved, wasPaying: false))
        XCTAssertNil(try banner(phase: .free(ended: false), wasPaying: true), "the relay says none, not ended")
    }

    func testOKEndsTheBannerAcrossARelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "relay-banner-\(UUID().uuidString)"))
        defaults.set(true, forKey: RelayAccountCenter.wasPayingKey)
        func center() -> RelayAccountCenter {
            RelayAccountCenter(
                link: RelayAccountLink(hasIdentity: { false }, account: { nil }, events: { nil }),
                store: FakeSubscriptionStore(), defaults: defaults
            ) { [] }
        }
        let first = center()
        XCTAssertNotNil(try banner(phase: .free(ended: true), wasPaying: first.wasPaying))
        XCTAssertNotNil(try banner(phase: .free(ended: true), wasPaying: center().wasPaying), "a relaunch keeps an undismissed loss")

        RelayBannerPress.run(.ok, session: nil, center: first) { XCTFail("OK opens nothing") }

        XCTAssertNil(try banner(phase: .free(ended: true), wasPaying: first.wasPaying))
        XCTAssertNil(try banner(phase: .free(ended: true), wasPaying: center().wasPaying))
    }

    func testAPayingReadEndsTheBanner() async throws {
        let bed = AccountBed()
        let token = try await bed.register()
        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "expired", for: .zero)
        bed.defaults.set(true, forKey: RelayAccountCenter.wasPayingKey)
        let center = bed.makeCenter()
        center.start()
        await center.foreground()?.value
        XCTAssertNotNil(try banner(phase: center.phase, wasPaying: center.wasPaying))

        try await bed.fake.setEntitlement(accountID: token.uuidString.lowercased(), state: "active", for: .seconds(86_400))
        await center.refresh()

        XCTAssertNil(try banner(phase: center.phase, wasPaying: center.wasPaying))
    }

    func testBackOnICloudIsNotSaidWhileThisHubIsStillOnTheRelay() throws {
        XCTAssertFalse(try XCTUnwrap(try banner(phase: .moved, wasPaying: true, route: relayRoute)).text.contains("back on"))
        XCTAssertFalse(try XCTUnwrap(try banner(phase: .free(ended: true), wasPaying: true, route: relayRoute)).text.contains("back on"))
        XCTAssertNotNil(try banner(phase: .free(ended: true), wasPaying: true, route: iCloudRoute))
        XCTAssertNotNil(try banner(phase: .free(ended: true), wasPaying: true, route: nil), "no hub: nothing contradicts it")
    }

    // MARK: - S34b: ended, the route not moved yet

    private var lapse: TransportRequestRecord { request(reason: TransportFollowerPolicy.lapseReason) }

    func testALapsedPhoneOnAClosedMacIsToldTheMoveIsComing() throws {
        let s34b = try XCTUnwrap(try banner(phase: .free(ended: true), wasPaying: true, route: relayRoute, request: lapse))
        XCTAssertEqual(s34b.text, "Your Relay subscription ended. Work Mac moves to iCloud when it's back.")
        XCTAssertEqual(s34b.actions, [.subscribe, .ok])
        XCTAssertFalse(s34b.busy)

        let keptCopy = request(refusal: .lapseNoAnswer, reason: TransportFollowerPolicy.lapseReason)
        let afterADay = try XCTUnwrap(try banner(phase: .free(ended: true), wasPaying: true, route: relayRoute, request: keptCopy))
        XCTAssertEqual(afterADay.text, s34b.text, "the copy stays: the Mac still moves when it's back")
        XCTAssertNil(afterADay.secondLine)
    }

    /// "moves to iCloud" holds only while the Mac has a request to answer.
    func testARefusingMacIsNotPromisedAMove() throws {
        let refused = try XCTUnwrap(try banner(
            phase: .free(ended: true), wasPaying: true, route: relayRoute,
            request: request(refusal: .notSupported, reason: TransportFollowerPolicy.lapseReason)
        ))
        XCTAssertEqual(refused.text, "Your Relay subscription ended.")
        XCTAssertEqual(refused.secondLine, TransportRequestRefusal.notSupported.message(macName: "Work Mac"))
        XCTAssertEqual(refused.secondLineTone, .red)
        XCTAssertEqual(refused.actions, [.switchToICloud, .subscribe, .ok], "its line says try again: the press stays, as on S50")

        let nothingAsked = try XCTUnwrap(try banner(phase: .free(ended: true), wasPaying: true, route: relayRoute))
        XCTAssertEqual(nothingAsked.text, "Your Relay subscription ended.")
        XCTAssertNil(nothingAsked.secondLine)
        XCTAssertEqual(nothingAsked.actions, [.subscribe, .ok])
    }

    func testS34bGivesWayOnlyWhereItShould() throws {
        XCTAssertNil(try banner(phase: .free(ended: true), wasPaying: false, route: relayRoute, request: lapse), "OK ends it")
        XCTAssertNil(
            try banner(phase: .free(ended: true), unconfirmed: true, wasPaying: true, route: relayRoute, request: lapse),
            "charged: nothing ended"
        )
        XCTAssertEqual(
            try banner(phase: .free(ended: true), wasPaying: true, route: relayRoute, relayOnly: true, request: lapse)?.text,
            "Work Mac needs Relay. Your subscription ended."
        )
        XCTAssertEqual(
            try banner(phase: .free(ended: true), wasPaying: true, route: relayRoute, unansweredFor: 12 * 60, request: lapse)?.text,
            outage, "an outage is what stops the Mac hearing now"
        )
        XCTAssertEqual(
            try banner(phase: .free(ended: true), wasPaying: true, route: iCloudRoute, request: lapse)?.text,
            "Your Relay subscription ended. This iPhone is back on iCloud.", "the route moved: S34"
        )
    }

    // MARK: - S41b: moved, the route not moved yet

    func testAMovedPhoneOnARelayRouteSaysSoWithNoPromise() throws {
        for request in [lapse, nil, request(refusal: .lapseNoAnswer, reason: TransportFollowerPolicy.lapseReason)] {
            let s41b = try XCTUnwrap(try banner(phase: .moved, wasPaying: true, route: relayRoute, request: request))
            XCTAssertEqual(s41b.text, "Your subscription moved to another iPhone.")
            XCTAssertNil(s41b.secondLine)
            XCTAssertEqual(s41b.actions, [.restore, .ok])
        }
    }

    func testAMovedPhoneOnARefusingMacSeesTheRefusal() throws {
        let refused = try XCTUnwrap(try banner(
            phase: .moved, wasPaying: true, route: relayRoute,
            request: request(refusal: .notSupported, reason: TransportFollowerPolicy.lapseReason)
        ))
        XCTAssertEqual(refused.text, "Your subscription moved to another iPhone.")
        XCTAssertEqual(refused.secondLine, TransportRequestRefusal.notSupported.message(macName: "Work Mac"))
        XCTAssertEqual(refused.secondLineTone, .red)
        XCTAssertEqual(refused.actions, [.switchToICloud, .restore, .ok], "its line says try again: the press stays, as on S50")
    }

    func testS41bGivesWayOnlyWhereItShould() throws {
        XCTAssertNil(try banner(phase: .moved, wasPaying: false, route: relayRoute, request: lapse), "OK ends it")
        XCTAssertEqual(
            try banner(phase: .moved, wasPaying: true, route: relayRoute, relayOnly: true, request: lapse)?.text,
            "Work Mac needs Relay. Your subscription moved to another iPhone."
        )
        XCTAssertEqual(try banner(phase: .moved, wasPaying: true, route: relayRoute, unansweredFor: 12 * 60, request: lapse)?.text, outage)
        XCTAssertEqual(
            try banner(phase: .moved, wasPaying: true, route: iCloudRoute, request: lapse)?.text,
            "Your Relay subscription moved to another iPhone. This iPhone is back on iCloud.", "the route moved: S33"
        )
    }

    // MARK: - A relay-only hub

    func testARelayOnlyHubShowsNeedsRelayBeforeMovedAndEnded() throws {
        let moved = try XCTUnwrap(try banner(
            phase: .moved, wasPaying: true, route: relayRoute, relayOnly: true, macName: "build-box"
        ))
        XCTAssertEqual(moved.text, "build-box needs Relay. Your subscription moved to another iPhone.")
        XCTAssertEqual(moved.actions, [.restore], "no OK: the hub gets nothing until the owner pays or unlinks")
        let ended = try XCTUnwrap(try banner(
            phase: .free(ended: true), wasPaying: true, route: relayRoute, relayOnly: true, macName: "build-box"
        ))
        XCTAssertEqual(ended.text, "build-box needs Relay. Your subscription ended.")
        XCTAssertEqual(ended.actions, [.subscribe])
    }

    func testNoBackOnICloudTextOnARelayOnlyHub() throws {
        let phases: [RelayAccountCenter.Phase] = [.moved, .free(ended: true), .free(ended: false)]
        for phase in phases {
            for wasPaying in [true, false] {
                let model = try XCTUnwrap(try banner(phase: phase, wasPaying: wasPaying, route: relayRoute, relayOnly: true))
                XCTAssertFalse(model.text.contains("iCloud"), "\(phase)")
                XCTAssertFalse(model.actions.contains(.ok), "\(phase)")
                XCTAssertFalse(model.actions.contains(.switchToICloud), "\(phase)")
            }
        }
    }

    func testARelayOnlyHubThatNeverHadASubscriptionIsNotToldItEnded() throws {
        let model = try XCTUnwrap(try banner(phase: .free(ended: false), route: relayRoute, relayOnly: true, macName: "build-box"))
        XCTAssertEqual(model.text, "build-box needs Relay.")
        XCTAssertEqual(model.actions, [.subscribe])
    }

    func testAPayingOrUnreadPhoneOnARelayOnlyHubIsNotToldItNeedsRelay() throws {
        XCTAssertNil(try banner(phase: .paying(grace: false, macs: []), route: relayRoute, relayOnly: true))
        XCTAssertNil(try banner(phase: .checking, route: relayRoute, relayOnly: true))
        XCTAssertNil(try banner(phase: .unknown, route: relayRoute, relayOnly: true))
    }

    // MARK: - Free on a relay Mac

    func testHubOnRelayFlagClearingEndsTheBanner() async throws {
        let bed = try await Bed.make(self, on: .cloudKit)
        let session = try await bed.orderedSession()
        bed.relayOps.paying = false
        func model() throws -> RelayBannerModel? {
            // What the view reads: the row in memory, refreshed by the follower's write.
            try banner(route: session.route, hubOnRelayAt: bed.root.linking.links.first { $0.hubID == session.hubID }?.link.hubOnRelayAt)
        }
        XCTAssertNil(try model())

        _ = try await bed.writeHubControl(.hubOnRelay, on: .cloudKit)
        await bed.fetch(session)
        XCTAssertEqual(try model()?.text, s30)

        try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .cloudKit)
        await bed.fetch(session)
        XCTAssertNil(try bed.row()?.link.hubOnRelayAt)
        XCTAssertNil(try model())
    }

    func testTheLastUpdateLineNamesAnOlderDay() throws {
        let yesterday = now.addingTimeInterval(-86_400)
        let clock = RecordingsFormat(calendar: .current, now: now).when(yesterday)
        XCTAssertEqual(try banner(hubOnRelayAt: now, lastUpdate: yesterday)?.secondLine, "Last update from Work Mac: \(clock)")
        XCTAssertNil(try banner(hubOnRelayAt: now, lastUpdate: nil)?.secondLine)
    }

    func testThePhaseDecidesWhetherSubscribeIsTrue() throws {
        XCTAssertNil(try banner(phase: .paying(grace: false, macs: []), hubOnRelayAt: now), "a paying phone is not free")
        for phase in [RelayAccountCenter.Phase.checking, .unknown] {
            let model = try XCTUnwrap(try banner(phase: phase, hubOnRelayAt: now), "\(phase)")
            XCTAssertEqual(model.text, s51, "not read yet: nothing says this phone isn't paying")
            XCTAssertEqual(model.actions, [])
        }
        XCTAssertEqual(try banner(phase: .moved, hubOnRelayAt: now)?.text, s30, "moved and dismissed")
    }

    // MARK: - A charged owner

    func testAnUnconfirmedPurchaseIsNeverToldToSubscribeOrThatItEnded() throws {
        let line = "Your purchase isn't confirmed yet."
        let free = try XCTUnwrap(try banner(phase: .free(ended: false), unconfirmed: true, hubOnRelayAt: now))
        XCTAssertEqual(free.text, s51)
        XCTAssertEqual(free.actions, [.confirmPurchase])

        let unknown = try XCTUnwrap(try banner(phase: .unknown, unconfirmed: true, hubOnRelayAt: now))
        XCTAssertEqual(unknown.actions, [.confirmPurchase])

        let needs = try XCTUnwrap(try banner(
            phase: .free(ended: true), unconfirmed: true, wasPaying: true, route: relayRoute, relayOnly: true, macName: "build-box"
        ))
        XCTAssertEqual(needs.text, "build-box needs Relay.")
        XCTAssertEqual(needs.actions, [.confirmPurchase])
        XCTAssertEqual(needs.title(for: .confirmPurchase), line)

        XCTAssertNil(try banner(phase: .free(ended: true), unconfirmed: true, wasPaying: true), "S34 would be false")

        // The relay's own word on a move stays, as on the card (S41): its Restore opens the screen with the purchase's frame.
        XCTAssertEqual(try banner(phase: .moved, unconfirmed: true, wasPaying: true)?.actions, [.restore, .ok])
        // Nothing an outage says depends on the purchase.
        XCTAssertEqual(try banner(phase: .unknown, unconfirmed: true, route: relayRoute, unansweredFor: 12 * 60)?.text, outage)
    }

    // MARK: - Tones

    func testTonesAreDeclared() throws {
        let models = try [
            banner(updateRequired: true),
            banner(phase: .free(ended: true), route: relayRoute, relayOnly: true),
            banner(phase: .moved, wasPaying: true),
            banner(phase: .free(ended: true), wasPaying: true),
            banner(hubOnRelayAt: now, lastUpdate: tenFortyOne),
            banner(route: relayRoute, unansweredFor: 12 * 60),
            banner(route: relayRoute, unansweredFor: 12 * 60, request: request()),
            banner(route: relayRoute, unansweredFor: 12 * 60, request: request(refusal: .unavailable))
        ]
        for model in models {
            let model = try XCTUnwrap(model)
            XCTAssertTrue(model.toneUses.allSatisfy { $0.tone != .orange }, "Relay is never a waiting-for-you element")
            XCTAssertEqual(model.toneUses.contains { $0.element == "relay banner actions" }, !model.actions.isEmpty)
            XCTAssertEqual(model.toneUses.contains { $0.element == "relay banner second line" }, model.secondLine != nil)
        }
        let refused = try XCTUnwrap(try banner(route: relayRoute, unansweredFor: 12 * 60, request: request(refusal: .unavailable)))
        XCTAssertTrue(refused.toneUses.contains { $0.element == "relay banner second line" && $0.tone == .red && $0.role == .status })
        let busy = try XCTUnwrap(try banner(route: relayRoute, unansweredFor: 12 * 60, request: request()))
        XCTAssertTrue(busy.toneUses.contains { $0.element == "relay banner second line" && $0.tone == .secondary })
    }

    // MARK: - HubSession

    func testTheOutageStartIsObserved() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        let changed = expectation(description: "the view hears the outage")
        withObservationTracking { _ = session.relayUnansweredSince } onChange: { changed.fulfill() }
        bed.fake.crash()
        await bed.fetch(session)
        await fulfillment(of: [changed], timeout: 5)
    }
}

/// `AppRoot` as the request's host, while its row writes fail.
@MainActor
private final class RowWriteFailingHost: TransportRequestHost {
    private let root: AppRoot
    var persistFails = true

    init(root: AppRoot) {
        self.root = root
    }

    func followerLink(hubID: String) -> LinkRecord? { root.followerLink(hubID: hubID) }
    func persistRoute(_ link: LinkRecord) -> Bool { persistFails ? false : root.persistRoute(link) }
    func makeOtherSide(hubID: String, route: HubRoute) throws -> SideTransport { try root.makeOtherSide(hubID: hubID, route: route) }
}
