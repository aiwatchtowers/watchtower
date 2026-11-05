import CryptoKit
import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Mac's Connection section (relay client Phase 4 Task 8, mockup S08–S19, S49, S52, S54, S56): the decision table,
/// first match wins, with the mockup's exact texts.
@MainActor
final class MacTransportModelTests: XCTestCase {
    private typealias Model = MacTransportModel
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let own = "4A1E7C10-6B1D-4B60-9C55-0C2C8D0A7E11"
    private let paying = RelayAccountCenter.Phase.paying(grace: false, macs: [])
    private let free = RelayAccountCenter.Phase.free(ended: false)
    private let lapse = TransportFollowerPolicy.lapseReason

    private var macKey: Data {
        // swiftlint:disable:next force_try
        try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32)).publicKey.rawRepresentation
    }

    private var macID: String { RelayIDs.deviceID(publicKey: macKey) }

    private func link(
        relay: Bool = false, transports: [String]? = ["cloudkit", "relay"], switchedBy: String? = nil, switchedAt: Date? = nil
    ) -> LinkRecord {
        var record = LinkRecord(
            hubID: "hub", macName: "Work Mac", scope: .private, ownerName: "", userRecordName: "", nonce: "n",
            dataShareURL: nil, relayShareURL: nil, deviceID: own, linkedAt: now, hubTransports: transports
        )
        if relay { record.setRelay(mac: macID) }
        record.switchedBy = switchedBy
        record.switchedAt = switchedAt
        return record
    }

    private func grant(ordered: Bool = true, coherent: Bool = true) -> DeviceGrant {
        DeviceGrant(
            deviceID: own, hubID: "hub", name: "iPhone", scope: .private, linked: true, typingAllowed: true,
            startSessionsAllowed: true, orderedActions: ordered ? 1 : nil, transports: ["cloudkit", "relay"],
            relayDeviceID: coherent ? macID : "not-the-key's-id", relayAuthPub: WireBytes.base64URL(macKey)
        )
    }

    private func facts(
        step: RelayUpgradeStep? = nil, refusal: RelayUpgradeRefusal? = nil, request: TransportRequestRecord? = nil, reachable: Bool = true
    ) -> SessionTransportFacts {
        SessionTransportFacts(upgradeStep: step, upgradeRefusal: refusal, request: request, macReachable: reachable)
    }

    private func request(_ refusal: TransportRequestRefusal? = nil, reason: String? = nil) -> TransportRequestRecord {
        TransportRequestRecord(target: .cloudKit, controlID: "c", reason: reason, at: now, refusal: refusal)
    }

    private func model(
        link: LinkRecord? = nil,
        grant: DeviceGrant?? = nil,
        phase: RelayAccountCenter.Phase? = nil,
        unconfirmed: Bool = false,
        availability: RelayAvailability? = nil,
        facts: SessionTransportFacts? = nil,
        at date: Date? = nil
    ) throws -> Model {
        Model(
            link: link ?? self.link(), grant: grant ?? self.grant(), phase: phase ?? paying, unconfirmedPurchase: unconfirmed,
            availability: try availability ?? .available(RelayOrigin("https://relay.example.com")),
            session: facts ?? self.facts(), macName: "Work Mac", ownDeviceID: own, now: date ?? now
        )
    }

    private struct Expected {
        var line: String?
        var chosen = false
        var enabled = false
        var action: Model.Action?
    }

    private func assertRow(_ row: Model.Row?, _ expected: Expected, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(row?.line, expected.line, "\(name) line", file: file, line: line)
        XCTAssertEqual(row?.chosen, expected.chosen, "\(name) chosen", file: file, line: line)
        XCTAssertEqual(row?.enabled, expected.enabled, "\(name) enabled", file: file, line: line)
        XCTAssertEqual(row?.action, expected.action, "\(name) action", file: file, line: line)
    }

    // swiftlint:disable:next function_body_length
    func testEveryChoiceStateHasItsCopyAndAction() throws {
        struct Case {
            let name: String
            let model: Model
            let relay: Expected
            let iCloud: Expected?
            var busyLine: String?
            var footnote: String?
        }
        let relayLine = "Instant, encrypted end to end"
        let free2 = "Free, slower"
        let chosenICloud = Expected(chosen: true, enabled: true)
        let relayRoute = self.link(relay: true)
        let onlyRelay = self.link(relay: true, transports: ["relay"])
        let tooSoonAt = now.addingTimeInterval(240)
        let table: [Case] = [
            Case(
                name: "S13 relay-only", model: try model(link: onlyRelay),
                relay: Expected(line: "This hub works over Relay only", chosen: true, enabled: false), iCloud: nil
            ),
            Case(
                name: "S13 relay-only, not paying", model: try model(link: onlyRelay, phase: free),
                relay: Expected(line: "This hub needs Relay", chosen: false, enabled: false), iCloud: nil
            ),
            Case(
                name: "S13 relay-only, moved", model: try model(link: onlyRelay, phase: .moved),
                relay: Expected(line: "This hub needs Relay", chosen: false, enabled: false), iCloud: nil
            ),
            Case(
                name: "S49 unavailable", model: try model(link: relayRoute, facts: facts(request: request(.unavailable))),
                relay: Expected(line: relayLine, chosen: true, enabled: false),
                iCloud: Expected(line: "Work Mac couldn't switch right now. Try again in a minute.", enabled: true, action: .tryAgain)
            ),
            Case(
                name: "S49 not supported", model: try model(link: relayRoute, facts: facts(request: request(.notSupported))),
                relay: Expected(line: relayLine, chosen: true, enabled: false),
                iCloud: Expected(line: "Work Mac can't switch from here. Update Watchtower on the Mac.", enabled: true, action: .tryAgain)
            ),
            Case(
                name: "S49 not ordered", model: try model(link: relayRoute, facts: facts(request: request(.notOrdered))),
                relay: Expected(line: relayLine, chosen: true, enabled: false),
                iCloud: Expected(line: "Update Watchtower on Work Mac to change how it connects.", enabled: true, action: .tryAgain)
            ),
            Case(
                name: "S52 no answer", model: try model(link: relayRoute, facts: facts(request: request(.macNoAnswer))),
                relay: Expected(line: relayLine, chosen: true, enabled: false),
                iCloud: Expected(
                    line: "Work Mac didn't answer for a day, so nothing changed. Try again when it's back.",
                    enabled: true, action: .tryAgain
                )
            ),
            Case(
                name: "S52 after a lapse: the copy still waits, nothing to press",
                model: try model(link: relayRoute, phase: free, facts: facts(request: request(.lapseNoAnswer, reason: lapse))),
                relay: Expected(line: relayLine, chosen: true, enabled: false),
                iCloud: Expected(line: "Work Mac didn't answer for a day. It moves to iCloud when it's back.")
            ),
            Case(
                name: "S17 toward iCloud", model: try model(link: relayRoute, facts: facts(request: request())),
                relay: Expected(line: relayLine), iCloud: Expected(line: free2), busyLine: "Switching to iCloud…"
            ),
            Case(
                name: "S16 request, Mac closed", model: try model(link: relayRoute, facts: facts(request: request(), reachable: false)),
                relay: Expected(line: relayLine), iCloud: Expected(line: free2),
                busyLine: "Waiting for Work Mac. It switches when it's back."
            ),
            Case(
                name: "S16 upgrade, Mac closed", model: try model(facts: facts(step: .requested, reachable: false)),
                relay: Expected(line: relayLine), iCloud: Expected(line: free2),
                busyLine: "Waiting for Work Mac. It switches when it's back."
            ),
            Case(
                name: "S15 upgrade running", model: try model(facts: facts(step: .vouching)),
                relay: Expected(line: relayLine), iCloud: Expected(line: free2),
                busyLine: "Switching to Relay…", footnote: "Getting Work Mac ready…"
            ),
            Case(
                name: "S19 checking, iCloud", model: try model(phase: .checking),
                relay: Expected(line: "Checking…"), iCloud: Expected(line: "Checking…", chosen: true, enabled: true)
            ),
            Case(
                name: "S19 checking, Relay route: leaving stays possible", model: try model(link: relayRoute, phase: .checking),
                relay: Expected(line: "Checking…", chosen: true),
                iCloud: Expected(line: free2, enabled: true, action: .chooseICloud)
            ),
            Case(
                name: "S18 kept refusal", model: try model(facts: facts(refusal: .unavailable)),
                relay: Expected(line: "Work Mac couldn't switch right now. Try again in a minute.", enabled: true, action: .tryAgain),
                iCloud: chosenICloud
            ),
            Case(
                name: "S18 reader not confirmed", model: try model(facts: facts(refusal: .readerNotConfirmed)),
                relay: Expected(
                    line: "Work Mac didn't confirm Relay. Update Watchtower on the Mac and try again.", enabled: true, action: .tryAgain
                ),
                iCloud: chosenICloud
            ),
            Case(
                name: "S11 too soon", model: try model(facts: facts(refusal: .tooSoon(retryAt: tooSoonAt))),
                relay: Expected(line: "Switching to Relay is possible again in 4 min"), iCloud: chosenICloud,
                footnote: "The Mac was switched less than 5 minutes ago."
            ),
            Case(
                name: "S14 slots full, kept",
                model: try model(phase: .paying(grace: false, macs: ["a", "b", "c"]), facts: facts(refusal: .vouch(.slotsFull))),
                relay: Expected(line: "Your subscription already has 3 Macs.", enabled: true, action: .manageMacs), iCloud: chosenICloud
            ),
            Case(
                name: "S12 no ordered actions", model: try model(grant: .some(grant(ordered: false))),
                relay: Expected(line: "Update Watchtower on this Mac to use Relay"), iCloud: chosenICloud
            ),
            Case(
                name: "S12 no coherent identity", model: try model(grant: .some(grant(coherent: false))),
                relay: Expected(line: "Update Watchtower on this Mac to use Relay"), iCloud: chosenICloud
            ),
            Case(
                name: "no grant read yet: nothing proves the Mac old", model: try model(grant: .some(nil)),
                relay: Expected(line: "Checking…"), iCloud: chosenICloud
            ),
            Case(
                name: "S56 unconfirmed, free", model: try model(phase: free, unconfirmed: true),
                relay: Expected(line: "Your purchase isn't confirmed yet.", enabled: true, action: .openSubscription), iCloud: chosenICloud
            ),
            Case(
                name: "S56 unconfirmed, unknown", model: try model(phase: .unknown, unconfirmed: true),
                relay: Expected(line: "Your purchase isn't confirmed yet.", enabled: true, action: .openSubscription), iCloud: chosenICloud
            ),
            Case(
                name: "S10 free", model: try model(phase: free),
                relay: Expected(line: "Subscribe to use Relay", enabled: true, action: .openSubscription),
                iCloud: Expected(line: free2, chosen: true, enabled: true)
            ),
            Case(
                name: "S10 ended", model: try model(phase: .free(ended: true)),
                relay: Expected(line: "Subscribe to use Relay", enabled: true, action: .openSubscription),
                iCloud: Expected(line: free2, chosen: true, enabled: true)
            ),
            Case(
                name: "S10 moved", model: try model(phase: .moved),
                relay: Expected(line: "Subscribe to use Relay", enabled: true, action: .openSubscription),
                iCloud: Expected(line: free2, chosen: true, enabled: true)
            ),
            Case(
                name: "S54 unknown", model: try model(phase: .unknown),
                relay: Expected(line: "Couldn't reach Relay."), iCloud: chosenICloud
            ),
            Case(
                name: "S14 three other Macs", model: try model(phase: .paying(grace: false, macs: ["a", "b", "c"])),
                relay: Expected(line: "Your subscription already has 3 Macs.", enabled: true, action: .manageMacs), iCloud: chosenICloud
            ),
            Case(
                name: "S09 paying, this Mac among the three", model: try model(phase: .paying(grace: false, macs: ["a", "b", macID])),
                relay: Expected(line: relayLine, enabled: true, action: .chooseRelay),
                iCloud: Expected(line: free2, chosen: true, enabled: true),
                footnote: "Applies to every phone of this Mac."
            ),
            Case(
                name: "S09 paying", model: try model(),
                relay: Expected(line: relayLine, enabled: true, action: .chooseRelay),
                iCloud: Expected(line: free2, chosen: true, enabled: true),
                footnote: "Applies to every phone of this Mac."
            ),
            Case(
                name: "S08 route relay", model: try model(link: relayRoute),
                relay: Expected(line: relayLine, chosen: true, enabled: true),
                iCloud: Expected(line: free2, enabled: true, action: .chooseICloud),
                footnote: "Applies to every phone of this Mac."
            ),
            Case(
                name: "S08 route relay, not paying: the way out stays", model: try model(link: relayRoute, phase: free),
                relay: Expected(line: relayLine, chosen: true, enabled: true),
                iCloud: Expected(line: free2, enabled: true, action: .chooseICloud),
                footnote: "Applies to every phone of this Mac."
            )
        ]
        for entry in table {
            XCTAssertEqual(entry.model.rows.first?.kind, .relay, entry.name)
            XCTAssertEqual(entry.model.rows.first?.title, "Relay", entry.name)
            assertRow(entry.model.rows.first, entry.relay, "\(entry.name) Relay")
            if let iCloud = entry.iCloud {
                XCTAssertEqual(entry.model.rows.count, 2, entry.name)
                XCTAssertEqual(entry.model.rows.last?.kind, .cloudKit, entry.name)
                XCTAssertEqual(entry.model.rows.last?.title, "iCloud", entry.name)
                assertRow(entry.model.rows.last, iCloud, "\(entry.name) iCloud")
            } else {
                XCTAssertEqual(entry.model.rows.count, 1, "\(entry.name): no iCloud row")
            }
            XCTAssertEqual(entry.model.busyLine, entry.busyLine, "\(entry.name) busyLine")
            XCTAssertEqual(entry.model.footnote, entry.footnote, "\(entry.name) footnote")
        }
    }

    // MARK: - No dead choice

    /// A refusal kept on the record never hides what actually helps now.
    func testAKeptRefusalNeverOffersADeadChoice() throws {
        // Slots freed since the refusal: the line would be false.
        let freed = try model(phase: .paying(grace: false, macs: ["a"]), facts: facts(refusal: .vouch(.slotsFull)))
        XCTAssertEqual(freed.rows.first?.action, .chooseRelay)
        // Not paying: Manage Macs and Try Again could only be refused again. Subscribing helps.
        for refusal: RelayUpgradeRefusal in [.vouch(.slotsFull), .notPaying, .vouch(.notPaying)] {
            let row = try model(phase: free, facts: facts(refusal: refusal)).rows.first
            XCTAssertEqual(row?.line, "Subscribe to use Relay", "\(refusal)")
            XCTAssertEqual(row?.action, .openSubscription, "\(refusal)")
        }
        // Paying again after a not-paying refusal: the phase's answer may be late, so the text and Try Again stay.
        let again = try model(facts: facts(refusal: .notPaying)).rows.first
        XCTAssertEqual(again?.action, .tryAgain)
        XCTAssertEqual(
            again?.line, "Work Mac stays on iCloud: Relay doesn't show a subscription for this iPhone yet. Try again in a few minutes.")
        // The two refusals with no text fall to the state underneath.
        for refusal: RelayUpgradeRefusal in [.relayOff, .noRelayIdentity] {
            XCTAssertEqual(try model(facts: facts(refusal: refusal)).rows.first?.action, .chooseRelay, "\(refusal)")
        }
    }

    /// The route says which rows can apply: a record left from before a move never paints a state the Mac is not in.
    func testARecordFromBeforeAMoveDoesNotPaintTheOtherRoute() throws {
        let onRelay = try model(link: link(relay: true), facts: facts(step: .vouching, refusal: .unavailable))
        XCTAssertNil(onRelay.busyLine)
        XCTAssertEqual(onRelay.rows.first?.chosen, true)
        XCTAssertEqual(onRelay.rows.last?.action, .chooseICloud)

        for record in [request(), request(.macNoAnswer)] {
            let onICloud = try model(facts: facts(request: record))
            XCTAssertNil(onICloud.busyLine)
            XCTAssertEqual(onICloud.rows.last?.chosen, true)
            XCTAssertEqual(onICloud.rows.first?.action, .chooseRelay)
        }
    }

    func testAClosedMacShowsWaitingNotAFailure() throws {
        for closed in [
            try model(facts: facts(step: .awaitingReader, reachable: false)),
            try model(link: link(relay: true), facts: facts(request: request(), reachable: false))
        ] {
            XCTAssertEqual(closed.busyLine, "Waiting for Work Mac. It switches when it's back.")
            XCTAssertTrue(closed.rows.allSatisfy { !$0.enabled && $0.action == nil }, "nothing to press while it waits")
            XCTAssertFalse(closed.toneUses.contains { $0.tone == .red }, "no failure's colour")
        }
    }

    func testTooSoonCountsDownAndReturnsTheAction() throws {
        let retryAt = now.addingTimeInterval(240)
        let session = facts(refusal: .tooSoon(retryAt: retryAt))

        let early = try model(facts: session)
        XCTAssertEqual(early.rows.first?.line, "Switching to Relay is possible again in 4 min")
        XCTAssertNil(early.rows.first?.action)
        XCTAssertEqual(early.rows.first?.enabled, false)
        XCTAssertEqual(early.footnote, "The Mac was switched less than 5 minutes ago.")

        let later = try model(facts: session, at: now.addingTimeInterval(90))
        XCTAssertEqual(later.rows.first?.line, "Switching to Relay is possible again in 3 min")
        XCTAssertEqual(later.rows.first?.enabled, false)

        let past = try model(facts: session, at: retryAt)
        XCTAssertEqual(past.rows.first?.line, "Instant, encrypted end to end")
        XCTAssertEqual(past.rows.first?.enabled, true)
        XCTAssertEqual(past.rows.first?.action, .chooseRelay)
    }

    func testFootnoteNamesWhoChanged() throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now).addingTimeInterval(10 * 3_600 + 42 * 60)
        let applies = "Applies to every phone of this Mac."
        let cases: [(String?, Date?, String)] = [
            (nil, nil, applies),
            ("", nil, applies),
            (own, today, "\(applies) Last changed by this iPhone at 10:42."),
            (own.lowercased(), today, "\(applies) Last changed by this iPhone at 10:42."),
            ("B7C1F5F0-3A77-4E4E-9D46-111111111111", today, "\(applies) Last changed by another iPhone at 10:42."),
            (lapse, today, "\(applies) Last changed when your subscription ended at 10:42."),
            (own, nil, "\(applies) Last changed by this iPhone.")
        ]
        for (by, at, expected) in cases {
            XCTAssertEqual(try model(link: link(relay: true, switchedBy: by, switchedAt: at)).footnote, expected, by ?? "nil")
            XCTAssertEqual(try model(link: link(switchedBy: by, switchedAt: at)).footnote, expected, by ?? "nil")
        }
        let yesterday = try model(link: link(switchedBy: own, switchedAt: today.addingTimeInterval(-86_400)), at: today)
        XCTAssertEqual(yesterday.footnote, "\(applies) Last changed by this iPhone yesterday at 10:42.")
        let older = try model(link: link(switchedBy: own, switchedAt: today.addingTimeInterval(-5 * 86_400)), at: today)
        let day = RecordingsFormat(calendar: calendar, now: today).when(today.addingTimeInterval(-5 * 86_400))
        XCTAssertEqual(older.footnote, "\(applies) Last changed by this iPhone on \(day).")
    }

    func testAStaleHeartbeatIsClosedAndLockedKeysAreNot() {
        XCTAssertTrue(SessionTransportFacts.macReachable(.reachable))
        XCTAssertFalse(SessionTransportFacts.macReachable(.unreachable))
        XCTAssertTrue(SessionTransportFacts.macReachable(.keysUnavailable), "a locked keychain proves nothing")
    }

    func testNoScreenWithoutRelay() throws {
        let off = try model(availability: .off(.notConfigured))
        XCTAssertTrue(off.rows.isEmpty)
        XCTAssertNil(off.footnote)
        XCTAssertNil(off.busyLine)
        XCTAssertTrue(off.toneUses.isEmpty)
    }

    func testSectionAndButtonTexts() {
        XCTAssertEqual(Model.sectionTitle, "Connection")
        XCTAssertEqual(Model.forgetTitle, "Forget This Mac")
        XCTAssertEqual(Model.title(for: .tryAgain), "Try Again")
        XCTAssertEqual(Model.title(for: .manageMacs), "Manage Macs")
        for action: Model.Action in [.chooseRelay, .chooseICloud, .openSubscription] {
            XCTAssertNil(Model.title(for: action), "\(action): the row itself is the press")
        }
    }

    func testEveryUpgradeStepHasTheSameBusyCopy() throws {
        for step in RelayUpgradeStep.allCases where step != .switched {
            let busy = try model(facts: facts(step: step))
            XCTAssertEqual(busy.busyLine, "Switching to Relay…", "\(step)")
            XCTAssertEqual(busy.footnote, "Getting Work Mac ready…", "\(step)")
            XCTAssertTrue(busy.rows.allSatisfy { !$0.enabled }, "\(step)")
            XCTAssertEqual(busy.rows.first?.busy, true, "\(step)")
            XCTAssertEqual(busy.rows.last?.busy, false, "\(step)")
        }
        let toICloud = try model(link: link(relay: true), facts: facts(request: request()))
        XCTAssertEqual(toICloud.rows.first?.busy, false)
        XCTAssertEqual(toICloud.rows.last?.busy, true)
    }

    func testTonesAreDeclared() throws {
        let plain = try model()
        XCTAssertEqual(plain.toneUses, [
            ToneUse(element: "connection Relay line", tone: .secondary, role: .info),
            ToneUse(element: "connection iCloud line", tone: .secondary, role: .info),
            ToneUse(element: "connection choice mark", tone: .accent, role: .info)
        ])
        func tone(_ model: Model, _ row: String) -> PhoneTone? {
            model.toneUses.first { $0.element == "connection \(row) line" }?.tone
        }
        XCTAssertEqual(tone(try model(phase: .unknown), "Relay"), .red)
        XCTAssertEqual(tone(try model(facts: facts(refusal: .unavailable)), "Relay"), .red)
        XCTAssertEqual(tone(try model(link: link(relay: true), facts: facts(request: request(.macNoAnswer))), "iCloud"), .red)
        XCTAssertEqual(tone(try model(link: link(relay: true), phase: free, facts: facts(request: request(.lapseNoAnswer))), "iCloud"), .secondary)
        XCTAssertEqual(tone(try model(phase: free), "Relay"), .secondary)
        XCTAssertFalse(try model(phase: free).toneUses.contains { $0.isWaitingOrAsk })
    }
}
