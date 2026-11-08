import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The left-behind phone's banner (S59) and the term's warning line (S61), relay client Phase 5, Task 17: the exact
/// strings, the surfaces, the held purchase and the refused row, the tones.
@MainActor
final class RelayBannerTermTests: XCTestCase {
    /// The first refusal at local noon on November 23, so the term's day is December 14.
    static let since = day(month: 11, day: 23)
    static let before = day(month: 12, day: 1)
    static let past = day(month: 12, day: 20)

    static func day(month: Int, day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)) ?? Date()
    }

    static let s59 = "Work Mac can't be reached over Relay any more. Link this iPhone to it again."
    static let beforeLine = "If this stays as it is, the link to Work Mac ends on December 14. "
        + "Its history and unsent actions on this iPhone will go."
    static let pastLine = "The link to Work Mac will end the next time this iPhone can confirm Relay still refuses it. "
        + "Its history and unsent actions on this iPhone will go."
    static let heldBanner = "This iPhone paid, but Relay hasn't seen it. Tap Restore Purchases to keep the link to Work Mac."
    static let heldNow = "This iPhone paid, but Relay hasn't seen it. See Settings → Macs."
    static let heldMacs = "This iPhone paid, but Relay hasn't seen it. Open the Relay card on this screen."
    static let refusedNow = "This iPhone paid, but Relay hasn't accepted it. The link to Work Mac stays while that purchase "
        + "is current. See Settings → Macs."
    static let refusedMacs = "This iPhone paid, but Relay hasn't accepted it. The link to Work Mac stays while that purchase "
        + "is current. Open the Relay card on this screen."

    /// A relay-only link to Work Mac, refused for `cause` since `since` (nil: not refused), its Mac moved when `moved`.
    static func link(_ cause: RelayRefusal?, moved: Bool = false, routed: Bool = false) -> LinkRecord {
        var link = LinkRecord(
            hubID: "hub-1", macName: "Work Mac", scope: .private, ownerName: "", userRecordName: "_owner", nonce: "n",
            dataShareURL: nil, relayShareURL: nil, transport: .relay, relayMacDeviceID: "mac",
            hubTransports: routed ? ["cloudkit", "relay"] : ["relay"])
        link.relayRefused = cause.map { RelayRefusedRecord(since: since, cause: $0) }
        link.macMoved = moved ? 4 : nil
        return link
    }

    private func banner(
        _ link: LinkRecord?,
        phase: RelayAccountCenter.Phase = .free(ended: true),
        hold: RelayTermHold = .none,
        unconfirmed: Bool = false,
        updateRequired: Bool = false,
        now: Date = before
    ) throws -> RelayBannerModel? {
        RelayBannerModel.banner(
            availability: .available(try RelayOrigin("https://relay.example.com")), phase: phase, unconfirmedPurchase: unconfirmed,
            updateRequired: updateRequired, wasPaying: true, route: .hostedRelay(macDeviceID: "mac"), relayOnly: true,
            hubOnRelayAt: nil, unansweredSince: nil, request: nil, pressRefusal: nil, lastUpdate: nil, macName: "Work Mac",
            now: now, link: link, termHold: hold)
    }

    private func line(_ link: LinkRecord, _ surface: RelayBannerModel.TermSurface, now: Date = before, hold: RelayTermHold = .none) -> String? {
        RelayBannerModel.termLine(for: link, surface: surface, now: now, heldPurchase: hold)
    }

    // MARK: - S59

    func testLinkGoneBeatsNeedsRelayAndSubscribe() throws {
        for link in [Self.link(.slot), Self.link(.lapse, moved: true), Self.link(nil, moved: true)] {
            let gone = try XCTUnwrap(try banner(link))
            XCTAssertEqual(gone.text, Self.s59)
            XCTAssertEqual(gone.actions, [.forget])
            XCTAssertEqual(gone.title(for: .forget), "Forget This Mac")
            XCTAssertFalse(gone.actions.contains(.subscribe))
            XCTAssertTrue(gone.speaksOfTerm)
        }
    }

    func testAPayingPhoneWithItsSlotGoneShowsLinkGone() throws {
        let gone = try XCTUnwrap(try banner(Self.link(.slot), phase: .paying(grace: false, macs: [])))
        XCTAssertEqual(gone.text, Self.s59)
        XCTAssertEqual(gone.secondLine, Self.beforeLine, "the term's warning under it")
    }

    func testLinkGoneBannerUsesNoOrange() throws {
        let gone = try XCTUnwrap(try banner(Self.link(.slot)))
        XCTAssertFalse(gone.toneUses.isEmpty)
        XCTAssertTrue(gone.toneUses.allSatisfy { $0.tone != .orange && $0.tone != .red }, "the calm card of ask #1040")
        XCTAssertEqual(gone.secondLineTone, .secondary)
    }

    /// Ask #1098: a paying phone holding the slot with its Mac moved has S59 and **Forget This Mac**, and no term.
    func testAPayingPhoneWithAMovedMacKeepsS59AndNoTerm() throws {
        let link = Self.link(nil, moved: true)
        let gone = try XCTUnwrap(try banner(link, phase: .paying(grace: false, macs: ["mac"]), now: Self.past))
        XCTAssertEqual(gone.text, Self.s59)
        XCTAssertNil(gone.secondLine, "no term, so no line")
        XCTAssertFalse(RelayTerm.isDue(link, now: Self.past.addingTimeInterval(365 * 86_400)))
    }

    /// Limit of ask #1081: a lapsed phone past its read window never read the move, and keeps needs-Relay with Subscribe.
    func testLapsedPastTheReadWindowKeepsNeedsRelay() throws {
        let needs = try XCTUnwrap(try banner(Self.link(.lapse)))
        XCTAssertEqual(needs.text, "Work Mac needs Relay. Your subscription ended.")
        XCTAssertEqual(needs.actions, [.subscribe])
        XCTAssertEqual(needs.secondLine, Self.beforeLine)
    }

    // MARK: - The warning (S61)

    func testTheBannerNamesTheDateFromTheFirstRefusal() throws {
        XCTAssertEqual(RelayTerm.date(of: try XCTUnwrap(Self.link(.lapse).relayRefused)), Self.since.addingTimeInterval(21 * 86_400))
        for surface in [RelayBannerModel.TermSurface.banner, .now, .macs] {
            XCTAssertEqual(line(Self.link(.lapse), surface), Self.beforeLine, "\(surface)")
            XCTAssertEqual(line(Self.link(.slot), surface), Self.beforeLine, "\(surface)")
        }
        XCTAssertEqual(try banner(Self.link(.lapse))?.secondLine, Self.beforeLine)
        XCTAssertEqual(try banner(Self.link(.lapse), phase: .moved)?.secondLine, Self.beforeLine)
    }

    /// The date is `since` plus 21 days, whatever the clock now says.
    func testTheDateDoesNotMove() {
        for now in [Self.since, Self.since.addingTimeInterval(86_400), Self.before] {
            XCTAssertEqual(line(Self.link(.lapse), .now, now: now), Self.beforeLine)
        }
    }

    func testPastTheDateTheLineSaysNextCheck() throws {
        for surface in [RelayBannerModel.TermSurface.banner, .now, .macs] {
            XCTAssertEqual(line(Self.link(.lapse), surface, now: Self.past), Self.pastLine, "\(surface)")
        }
        XCTAssertEqual(try banner(Self.link(.lapse), now: Self.past)?.secondLine, Self.pastLine)
    }

    func testALapseEndRemovesTheLine() throws {
        let cleared = Self.link(nil)
        for surface in [RelayBannerModel.TermSurface.banner, .now, .macs] {
            XCTAssertNil(line(cleared, surface))
        }
        XCTAssertNil(try banner(cleared)?.secondLine)
    }

    func testTheWarningLineUsesNoOrange() throws {
        let needs = try XCTUnwrap(try banner(Self.link(.lapse)))
        XCTAssertEqual(needs.secondLineTone, .secondary)
        XCTAssertTrue(needs.toneUses.allSatisfy { $0.tone != .orange })
        let row = NowTermRow(id: "hub-1", title: "Work Mac", line: Self.beforeLine)
        XCTAssertEqual(row.toneUse.tone, .secondary)
    }

    func testARoutedLinkShowsNoLine() {
        var routed = Self.link(nil, routed: true)
        routed.setCloudKit(left: nil)
        XCTAssertNil(line(routed, .now))
        XCTAssertFalse(RelayTerm.isDue(routed, now: Self.past))
    }

    // MARK: - A held purchase, a refused row

    func testAHeldPurchaseShowsRestorePurchases() throws {
        let moved = try XCTUnwrap(try banner(Self.link(.lapse), phase: .moved, hold: .held))
        XCTAssertEqual(moved.secondLine, Self.heldBanner)
        XCTAssertEqual(moved.actions, [.restore])
        XCTAssertEqual(moved.title(for: .restore), "Restore Purchases")
    }

    /// Ask #1104: `.free` gains **Restore Purchases** while a purchase is held; **Subscribe** stays.
    func testTheHeldLineOnFreeGainsRestore() throws {
        let free = try XCTUnwrap(try banner(Self.link(.lapse), hold: .held))
        XCTAssertEqual(free.text, "Work Mac needs Relay. Your subscription ended.")
        XCTAssertEqual(free.secondLine, Self.heldBanner)
        XCTAssertEqual(free.actions, [.subscribe, .restore])
        XCTAssertEqual(try banner(Self.link(.lapse))?.actions, [.subscribe], "no held purchase, no Restore")
    }

    func testRestorePurchasesIsNamedOnlyBesideItsButton() throws {
        let link = Self.link(.lapse)
        XCTAssertEqual(line(link, .now, hold: .held), Self.heldNow)
        XCTAssertEqual(line(link, .macs, hold: .held), Self.heldMacs)
        let banner = try XCTUnwrap(try banner(link, hold: .held))
        XCTAssertTrue(banner.actions.contains(.restore), "the banner names it beside its button")
        for text in [line(link, .now, hold: .held), line(link, .macs, hold: .held), try self.banner(Self.link(.slot), hold: .held)?.secondLine] {
            XCTAssertFalse((text ?? "").contains("Restore Purchases"), text ?? "")
        }
    }

    func testNoPurchaseHoldsASlotLoss() throws {
        for surface in [RelayBannerModel.TermSurface.banner, .now, .macs] {
            XCTAssertEqual(line(Self.link(.slot), surface, hold: .held), Self.beforeLine, "\(surface)")
            XCTAssertEqual(line(Self.link(.slot), surface, now: Self.past, hold: .refusedRow), Self.pastLine, "\(surface)")
        }
        XCTAssertFalse(RelayTerm.purchaseHolds(Self.link(.slot)))
        XCTAssertEqual(try banner(Self.link(.slot), hold: .held)?.actions, [.forget])
    }

    func testAMovedMacWithALapseShowsNoHeldLineAndIsNotHeld() throws {
        let link = Self.link(.lapse, moved: true)
        XCTAssertFalse(RelayTerm.purchaseHolds(link))
        let gone = try XCTUnwrap(try banner(link, phase: .moved, hold: .held))
        XCTAssertEqual(gone.text, Self.s59)
        XCTAssertEqual(gone.secondLine, Self.beforeLine)
        XCTAssertEqual(line(link, .now, hold: .held), Self.beforeLine)
    }

    /// A refused row (`transferLimit`, `notImplemented`, `updateRequired`): no held line; past the date the banner has
    /// no line, its own words say where the purchase stands.
    func testATransferLimitWaitsWithNoHeldLine() throws {
        let link = Self.link(.lapse)
        let pastBanner = try XCTUnwrap(try banner(link, hold: .refusedRow, unconfirmed: true, now: Self.past))
        XCTAssertEqual(pastBanner.text, "Work Mac needs Relay.")
        XCTAssertEqual(pastBanner.actions, [.confirmPurchase])
        XCTAssertNil(pastBanner.secondLine)
        XCTAssertTrue(pastBanner.speaksOfTerm, "so Now shows no row for it")
        XCTAssertEqual(try banner(link, hold: .refusedRow, unconfirmed: true)?.secondLine, Self.beforeLine, "before the date")
    }

    func testASecondMacWithARefusedRowPastTheDateSaysWhy() {
        let link = Self.link(.lapse)
        XCTAssertEqual(line(link, .now, now: Self.past, hold: .refusedRow), Self.refusedNow)
        XCTAssertEqual(line(link, .macs, now: Self.past, hold: .refusedRow), Self.refusedMacs)
        XCTAssertNil(line(link, .banner, now: Self.past, hold: .refusedRow))
    }
}
