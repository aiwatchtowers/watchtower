import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Settings → Macs' Relay card (relay client Phase 4 Task 7, mockup S01–S06, S41, S55): every phase's rows, line and
/// action, with the mockup's exact texts.
@MainActor
final class RelayCardModelTests: XCTestCase {
    private func available() throws -> RelayAvailability {
        .available(try RelayOrigin("https://relay.example.com"))
    }

    private func card(
        _ phase: RelayAccountCenter.Phase, unconfirmed: Bool = false, availability: RelayAvailability? = nil
    ) throws -> RelayCardModel {
        try XCTUnwrap(RelayCardModel(
            availability: try availability ?? self.available(), phase: phase, unconfirmedPurchase: unconfirmed, slotLimit: 3
        ))
    }

    private func rows(_ model: RelayCardModel) -> [[String]] {
        model.rows.map { [$0.title, $0.value ?? ""] }
    }

    func testOnlyACardWithNoLinkRowIsItselfThePress() throws {
        XCTAssertEqual(try card(.free(ended: false)).cardAction, .openSubscription)
        XCTAssertEqual(try card(.free(ended: false), unconfirmed: true).cardAction, .openSubscription)
        XCTAssertNil(try card(.free(ended: true)).cardAction, "Subscribe is its own link row")
        XCTAssertNil(try card(.unknown).cardAction, "Retry is its own link row")
        XCTAssertNil(try card(.moved).cardAction)
        XCTAssertNil(try card(.paying(grace: false, macs: [])).cardAction)
    }

    func testEveryPhaseHasItsRowsAndAction() throws {
        struct Case {
            let phase: RelayAccountCenter.Phase
            let rows: [[String]]
            let line: String?
            let action: RelayCardModel.Action?
            let actionTitle: String?
        }
        let table: [Case] = [
            Case(phase: .free(ended: false), rows: [["Relay", "Not subscribed"]], line: nil, action: .openSubscription, actionTitle: nil),
            Case(phase: .checking, rows: [["Relay", "Checking…"]], line: nil, action: nil, actionTitle: nil),
            Case(phase: .unknown, rows: [["Relay", ""]], line: "Couldn't reach Relay.", action: .retry, actionTitle: "Retry"),
            Case(
                phase: .paying(grace: false, macs: ["a", "b"]),
                rows: [["Subscription", "Active"], ["Macs on this subscription", "2 of 3"]], line: nil, action: nil, actionTitle: nil
            ),
            Case(
                phase: .paying(grace: true, macs: ["a", "b"]),
                rows: [["Subscription", "Active"], ["Macs on this subscription", "2 of 3"]],
                line: "Active. Check your payment in the App Store.", action: nil, actionTitle: nil
            ),
            Case(
                phase: .free(ended: true), rows: [["Subscription", "Ended"]], line: "Your subscription ended.",
                action: .openSubscription, actionTitle: "Subscribe"
            ),
            Case(
                phase: .moved, rows: [["Subscription", "Moved"]], line: "Your subscription moved to another iPhone.",
                action: .restore, actionTitle: "Restore Purchases"
            )
        ]
        for entry in table {
            let model = try card(entry.phase)
            XCTAssertEqual(rows(model), entry.rows, "\(entry.phase)")
            XCTAssertEqual(model.line, entry.line, "\(entry.phase)")
            XCTAssertEqual(model.action, entry.action, "\(entry.phase)")
            XCTAssertEqual(model.actionTitle, entry.actionTitle, "\(entry.phase)")
        }
    }

    func testAnUnconfirmedPurchaseIsNeverNotSubscribed() throws {
        for phase: RelayAccountCenter.Phase in [.free(ended: false), .free(ended: true), .unknown] {
            let model = try card(phase, unconfirmed: true)
            XCTAssertEqual(rows(model), [["Subscription", "Not confirmed"]], "\(phase)")
            XCTAssertEqual(model.line, "Your purchase isn't confirmed yet.", "\(phase)")
            XCTAssertEqual(model.action, .openSubscription, "\(phase)")
            XCTAssertNil(model.actionTitle, "the line row itself opens it")
        }
        XCTAssertEqual(try card(.paying(grace: false, macs: []), unconfirmed: true).rows.first?.value, "Active")
        XCTAssertEqual(try card(.moved, unconfirmed: true).action, .restore)
        XCTAssertEqual(try card(.checking, unconfirmed: true).rows.first?.value, "Checking…")
    }

    func testAnUnavailableRelayHasNoCard() {
        for availability in [RelayAvailability.off(.notConfigured), .off(.unsupportedDevice)] {
            XCTAssertNil(RelayCardModel(
                availability: availability, phase: .free(ended: false), unconfirmedPurchase: true, slotLimit: 3
            ))
        }
    }

    func testTheSlotCountReadsNOfThree() throws {
        for (macs, text) in [([], "0 of 3"), (["a"], "1 of 3"), (["a", "b", "c"], "3 of 3")] {
            XCTAssertEqual(try card(.paying(grace: false, macs: macs)).rows.last?.value, text)
        }
        let two = try XCTUnwrap(RelayCardModel(
            availability: try available(), phase: .paying(grace: false, macs: ["a"]), unconfirmedPurchase: false, slotLimit: 2
        ))
        XCTAssertEqual(two.rows.last?.value, "1 of 2")
    }

    func testCardTonesAreDeclared() throws {
        for phase: RelayAccountCenter.Phase in [
            .checking, .unknown, .free(ended: false), .free(ended: true), .paying(grace: false, macs: []),
            .paying(grace: true, macs: []), .moved
        ] {
            let model = try card(phase)
            XCTAssertFalse(model.toneUses.isEmpty, "\(phase)")
            XCTAssertTrue(model.toneUses.allSatisfy { $0.tone != .orange }, "Relay is never a waiting-for-you element")
        }
        let grace = try card(.paying(grace: true, macs: []))
        XCTAssertTrue(grace.toneUses.contains { $0.element == "relay card line" && $0.tone == .secondary })
        XCTAssertTrue(try card(.unknown).toneUses.contains { $0.element == "relay card line" && $0.tone == .red })
    }

    func testAnEmptyOriginShowsNoRelayUI() throws {
        XCTAssertNil(RelayCardModel(
            availability: .off(.notConfigured), phase: .free(ended: false), unconfirmedPurchase: false, slotLimit: 3
        ))
        // The Macs list is today's: no transport line on any row.
        var link = LinkRecord(
            hubID: "hub-acme", macName: "Acme Mac", scope: .private, ownerName: "o", userRecordName: "o", nonce: "n",
            dataShareURL: nil, relayShareURL: nil, deviceID: "device-1"
        )
        link.switchedBy = "device-1"
        link.switchedAt = Date()
        let row = HubRow(
            link: link, flavor: nil, sortOrder: 0, state: .linked, grantMissingSince: nil, lastHeartbeatAt: Date(), linkedOn: Date()
        )
        let off = HubListModel.items(rows: [row], sessions: [:], activeHubID: nil, now: Date())
        XCTAssertNil(off.first?.transportLine)
        let env = AppEnvironment(backend: .inMemoryDemo, defaults: try XCTUnwrap(UserDefaults(suiteName: "p4t7-\(UUID())")))
        XCTAssertNil(env.relayAccount, "no center without a relay")
        XCTAssertTrue(env.hubListItems([row], now: Date()).allSatisfy { $0.transportLine == nil })
        let shown = HubListModel.items(rows: [row], sessions: [:], showsTransport: true, activeHubID: nil, now: Date())
        XCTAssertEqual(shown.first?.transportLine?.hasPrefix("iCloud · switched by this iPhone"), true)
    }
}
