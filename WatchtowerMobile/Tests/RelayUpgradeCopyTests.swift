import Foundation
import WatchtowerHostedRelay
import XCTest
@testable import WatchtowerMobile

/// The upgrade's texts (relay client Phase 3b Task 19; Open decision 3, ask #980; mockup section 3; Owner approval 3
/// for the Task 10 rows). No view shows them before Phase 4.
final class RelayUpgradeCopyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func message(_ refusal: RelayUpgradeRefusal) -> String? {
        refusal.message(macName: "Work Mac", now: now)
    }

    func testTooSoon() {
        let refusal = RelayUpgradeRefusal.tooSoon(retryAt: now.addingTimeInterval(200))
        XCTAssertEqual(message(refusal), "Switching to Relay is possible again in 4 min")
        XCTAssertEqual(refusal.footnote, "The Mac was switched less than 5 minutes ago.")
        XCTAssertEqual(message(.tooSoon(retryAt: now)), "Switching to Relay is possible again in 1 min", "never 0")
    }

    func testNotPaying() {
        XCTAssertEqual(
            message(.notPaying),
            "Work Mac stays on iCloud: Relay doesn't show a subscription for this iPhone yet. Try again in a few minutes.")
    }

    func testUnavailable() {
        XCTAssertEqual(message(.unavailable), "Work Mac couldn't switch right now. Try again in a minute.")
    }

    func testNotSupported() {
        XCTAssertEqual(message(.notSupported), "Work Mac can't switch to Relay. Update Watchtower on the Mac.")
    }

    func testReaderNotConfirmed() {
        XCTAssertEqual(message(.readerNotConfirmed), "Work Mac didn't confirm Relay. Update Watchtower on the Mac and try again.")
    }

    /// `.vouch(_)` shows the Task 10 row's text for the same refusal.
    func testVouchRefusalsUseTheLinkRowTexts() {
        let rows: [(HostedRelayPairing.VouchRefusal, PromotedLink.Reason)] = [
            (.notPaying, .notPaying), (.hubNotOnRelay, .hubNotOnRelay),
            (.slotsFull, .slotsFull), (.notConfirmed, .notConfirmed)
        ]
        for (refusal, reason) in rows {
            XCTAssertEqual(message(.vouch(refusal)), reason.message(macName: "Work Mac"), "\(refusal)")
        }
        XCTAssertEqual(message(.vouch(.slotsFull)), "Relay already has 3 Macs. Remove one, then try again, or cancel this link.")
    }

    /// The upgrade's own texts for its two extra refusals (ask #997); Task 10's link-time texts are unchanged.
    func testUpgradeOnlyTexts() {
        XCTAssertEqual(
            message(.replacementLimit), "Work Mac stays on iCloud: too many Mac changes on Relay this month. Try again later.")
        XCTAssertEqual(message(.vouch(.updateRequired)), "Update Watchtower on this iPhone to move Work Mac to Relay.")
        XCTAssertEqual(PromotedLink.Reason.updateApp.message(macName: "Work Mac"), "Update Watchtower to finish this link, or cancel it.")
        XCTAssertEqual(
            PromotedLink.Reason.replacementLimit.message(macName: "Work Mac"),
            "Too many Mac changes on Relay. Try again later, or cancel this link.")
    }

    /// No relay on this phone, or a hub that names no relay identity: the choice is not offered, so there is no text.
    func testRefusalsThatHideTheChoiceHaveNoText() {
        XCTAssertNil(message(.relayOff))
        XCTAssertNil(message(.noRelayIdentity))
        XCTAssertNil(RelayUpgradeRefusal.notPaying.footnote)
    }

    /// Every refusal survives the `LinkRecord` JSON.
    func testRefusalsRoundTrip() throws {
        let refusals: [RelayUpgradeRefusal] = [
            .noRelayIdentity, .relayOff, .vouch(.slotsFull), .vouch(.attestationBackoff(until: now)), .tooSoon(retryAt: now),
            .notPaying, .unavailable, .notSupported, .readerNotConfirmed, .replacementLimit
        ]
        for refusal in refusals {
            let data = try JSONEncoder().encode(refusal)
            XCTAssertEqual(try JSONDecoder().decode(RelayUpgradeRefusal.self, from: data), refusal)
        }
    }
}
