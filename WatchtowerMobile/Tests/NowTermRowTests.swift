import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Now's quiet row for a refused Mac and the Settings → Macs row's line (relay client Phase 5, Task 17, S61).
@MainActor
final class NowTermRowTests: XCTestCase {
    private typealias Term = RelayBannerTermTests

    private func row(_ hubID: String, _ name: String, _ link: LinkRecord) -> HubRow {
        let renamed = LinkRecord(
            hubID: hubID, macName: name, scope: .private, ownerName: "", userRecordName: "_owner", nonce: "n",
            dataShareURL: nil, relayShareURL: nil, transport: .relay, relayMacDeviceID: "mac-\(hubID)",
            hubTransports: link.hubTransports, relayRefused: link.relayRefused, macMoved: link.macMoved)
        return HubRow(link: renamed, flavor: nil, sortOrder: 0, state: .linked, grantMissingSince: nil, lastHeartbeatAt: nil, linkedOn: Term.since)
    }

    private func needsRelayBanner(_ link: LinkRecord, now: Date = Term.before) throws -> RelayBannerModel? {
        RelayBannerModel.banner(
            availability: .available(try RelayOrigin("https://relay.example.com")), phase: .free(ended: true),
            unconfirmedPurchase: false, updateRequired: false, wasPaying: true, route: .hostedRelay(macDeviceID: "mac"),
            relayOnly: true, hubOnRelayAt: nil, unansweredSince: nil, request: nil, pressRefusal: nil, lastUpdate: nil,
            macName: link.macName, now: now, link: link, termHold: .none)
    }

    func testAnotherMacsTermShowsOnNow() throws {
        let work = row("work", "Work Mac", Term.link(.lapse))
        let home = row("home", "Home Mac", Term.link(.lapse))
        let banner = try needsRelayBanner(work.link)
        let rows = NowTermRow.rows(links: [work, home], activeHubID: "work", activeBanner: banner, hold: .none, now: Term.before)
        XCTAssertEqual(rows.map(\.id), ["home"], "the Mac on screen has its banner's line")
        XCTAssertEqual(rows.first?.title, "Home Mac")
        XCTAssertEqual(rows.first?.line, "If this stays as it is, the link to Home Mac ends on December 14. "
            + "Its history and unsent actions on this iPhone will go.")
    }

    func testTheRowOnNowOpensMacs() {
        let row = NowTermRow(id: "home", title: "Home Mac", line: "x")
        XCTAssertEqual(row.destination, .macs)
        XCTAssertTrue(NowRoute.allCases.contains(.macs))
    }

    /// The Mac on screen whose banner carries no term ("Update Watchtower…", an unknown phase): its row shows instead.
    func testNoBannerFallsBackToTheRow() throws {
        let work = row("work", "Work Mac", Term.link(.lapse))
        let update = RelayBannerModel.banner(
            availability: .available(try RelayOrigin("https://relay.example.com")), phase: .free(ended: true),
            unconfirmedPurchase: true, updateRequired: true, wasPaying: true, route: .hostedRelay(macDeviceID: "mac"),
            relayOnly: true, hubOnRelayAt: nil, unansweredSince: nil, request: nil, pressRefusal: nil, lastUpdate: nil,
            macName: "Work Mac", now: Term.past, link: work.link, termHold: .refusedRow)
        XCTAssertEqual(update?.text, "Update Watchtower from the App Store to keep using Relay.")
        let rows = NowTermRow.rows(links: [work], activeHubID: "work", activeBanner: update, hold: .refusedRow, now: Term.past)
        XCTAssertEqual(rows.map(\.line), [Term.refusedNow], "S61n: the row for the Mac on screen says why")
        let none = NowTermRow.rows(links: [work], activeHubID: "work", activeBanner: nil, hold: .none, now: Term.past)
        XCTAssertEqual(none.map(\.line), [Term.pastLine])
    }

    func testNowsRowSendsAHeldPurchaseToMacs() {
        let home = row("home", "Home Mac", Term.link(.lapse))
        let rows = NowTermRow.rows(links: [home], activeHubID: "work", activeBanner: nil, hold: .held, now: Term.before)
        XCTAssertEqual(rows.map(\.line), ["This iPhone paid, but Relay hasn't seen it. See Settings → Macs."])
        XCTAssertEqual(rows.first?.destination, .macs)
    }

    func testARoutedOrUnrefusedMacHasNoRow() {
        let fine = row("home", "Home Mac", Term.link(nil))
        XCTAssertTrue(NowTermRow.rows(links: [fine], activeHubID: "work", activeBanner: nil, hold: .none, now: Term.past).isEmpty)
    }

    /// S59's **Forget This Mac** asks first, with Settings → Macs' own words for a linked Mac.
    func testForgetThisMacAsksAsMacsDoes() {
        let ask = MacsModel.Ask(forgetting: "work", name: "Work Mac")
        XCTAssertEqual(ask.title, "Forget Work Mac?")
        XCTAssertEqual(ask.button, "Forget")
        XCTAssertEqual(ask.message, "This unlinks the Mac and deletes its data on this iPhone.")
        XCTAssertEqual(ask.hubID, "work")
    }

    /// A link saved before Task 17 (no `macMoved`, a mark with no `termReadAt`) still reads, and an unreadable new
    /// field reads as absent, never making the link unreadable.
    func testALinkSavedBeforeTheTermDecodes() throws {
        let json = #"{"hubID":"h","macName":"Work Mac","scope":"private","ownerName":"","userRecordName":"u","nonce":"n","#
            + #""transport":"relay","relayMacDeviceID":"mac","relayRefused":{"since":0,"cause":"lapse"},"macMoved":"x"}"#
        let link = try JSONDecoder().decode(LinkRecord.self, from: Data(json.utf8))
        XCTAssertEqual(link.relayRefused?.cause, .lapse)
        XCTAssertNil(link.relayRefused?.termReadAt)
        XCTAssertNil(link.macMoved, "unreadable: absent")
        var marked = link
        marked.macMoved = 4
        marked.relayRefused?.termReadAt = Date(timeIntervalSince1970: 10)
        let again = try JSONDecoder().decode(LinkRecord.self, from: try JSONEncoder().encode(marked))
        XCTAssertEqual(again, marked)
    }

    // MARK: - Settings → Macs

    private func items(_ rows: [HubRow], hold: RelayTermHold = .none, now: Date = Term.before) -> [HubListItem] {
        HubListModel.items(rows: rows, sessions: [:], showsTransport: true, termHold: hold, activeHubID: nil, now: now)
    }

    func testTheMacsRowShowsTheTermLine() {
        let home = row("home", "Home Mac", Term.link(.lapse))
        XCTAssertEqual(items([home]).first?.termLine, "If this stays as it is, the link to Home Mac ends on December 14. "
            + "Its history and unsent actions on this iPhone will go.")
        XCTAssertEqual(items([home], now: Term.past).first?.termLine, "The link to Home Mac will end the next time this iPhone "
            + "can confirm Relay still refuses it. Its history and unsent actions on this iPhone will go.")
        XCTAssertNil(items([row("work", "Work Mac", Term.link(nil))]).first?.termLine)
        XCTAssertNil(
            HubListModel.items(rows: [home], sessions: [:], showsTransport: false, activeHubID: nil, now: Term.before).first?.termLine,
            "a build with no relay shows today's row")
    }

    func testTheMacsRowSendsAHeldPurchaseToTheCard() {
        let home = row("home", "Home Mac", Term.link(.lapse))
        XCTAssertEqual(items([home], hold: .held).first?.termLine, "This iPhone paid, but Relay hasn't seen it. Open the Relay card on this screen.")
        XCTAssertEqual(
            items([home], hold: .refusedRow, now: Term.past).first?.termLine,
            "This iPhone paid, but Relay hasn't accepted it. The link to Home Mac stays while that purchase is current. "
                + "Open the Relay card on this screen.")
    }
}
