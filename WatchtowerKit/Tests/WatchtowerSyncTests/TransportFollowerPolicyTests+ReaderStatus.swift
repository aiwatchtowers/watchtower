import Foundation
import WatchtowerSync
import XCTest

/// Losing reader status (relay client Phase 5, Task 13): `slotLost`, a relay-only link's lapse, and the keys an opened
/// `hub_on_relay` drops.
final class TransportFollowerPolicyReaderStatusTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(route: TransportKind = .relay, otherRoute: Bool, lapseRequested: Bool = false) -> FollowerState {
        FollowerState(route: route, newestEpoch: 3, canUseRelay: .yes, lapseRequested: lapseRequested, hasOtherRoute: otherRoute)
    }

    /// A relay-only link: withdraw and list, the term starts, the route stays and no key is erased; the request still
    /// goes, as today.
    func testRelayOnlyLapseWithdrawsAndLists() {
        let (next, commands) = TransportFollowerPolicy.decide(.relayLapsed, state: state(otherRoute: false), now: base)
        XCTAssertEqual(commands, [
            .withdrawUnechoed, .markRefused(.lapse), .requestSwitch(target: .cloudKit, reason: TransportFollowerPolicy.lapseReason)
        ])
        XCTAssertEqual(next.route, .relay, "the route stays relay")
        XCTAssertFalse(commands.contains(.dropEphemeral), "keys kept")
        XCTAssertFalse(commands.contains(.listUnechoedAsUndelivered), "only withdrawn rows are listed")
        // A repeated notice withdraws again (a refused delete left a row sent) and asks nothing new.
        let (_, again) = TransportFollowerPolicy.decide(.relayLapsed, state: next, now: base)
        XCTAssertEqual(again, [.withdrawUnechoed, .markRefused(.lapse), .ignore])
    }

    /// With another route the lapse is today's: ask, keep keys, nothing withdrawn.
    func testRelayLapsedQueuesTheRequestAndKeepsKeys() {
        let (_, commands) = TransportFollowerPolicy.decide(.relayLapsed, state: state(otherRoute: true), now: base)
        XCTAssertEqual(commands, [.requestSwitch(target: .cloudKit, reason: TransportFollowerPolicy.lapseReason)])
    }

    func testSlotLostWithASubscriptionWithdrawsAndLists() {
        let (next, commands) = TransportFollowerPolicy.decide(.slotLost, state: state(otherRoute: false), now: base)
        XCTAssertEqual(commands, [.withdrawUnechoed, .markRefused(.slot), .ignore])
        XCTAssertEqual(next, state(otherRoute: false), "no move, no lapse: the subscription stands")
    }

    func testSlotLostWithARouteWithdrawsMovesAndLists() {
        let (next, commands) = TransportFollowerPolicy.decide(.slotLost, state: state(otherRoute: true), now: base)
        XCTAssertEqual(commands, [
            .withdrawUnechoed, .moveRoute(to: .cloudKit, epoch: 3, by: "", at: base), .drainMailbox(on: .relay), .ignore
        ])
        XCTAssertEqual(next.route, .cloudKit)
        XCTAssertEqual(next.leftTransport, .relay)
        XCTAssertFalse(commands.contains(.dropEphemeral), "keys kept: the hub may not have acted yet")
        // The hub_on_relay read afterwards lists what the withdrawal left and is marked handled.
        let (_, notice) = TransportFollowerPolicy.decide(.hubOnRelay(controlID: "c-5"), state: next, now: base)
        XCTAssertEqual(notice, [.listUnechoedAsUndelivered, .dropEphemeral, .markHandled(controlID: "c-5")])
    }

    func testSlotLostKeepsKeys() {
        for other in [true, false] {
            let (_, commands) = TransportFollowerPolicy.decide(.slotLost, state: state(otherRoute: other), now: base)
            XCTAssertFalse(commands.contains(.dropEphemeral))
        }
    }

    func testSlotLostOffTheRelayDoesNothing() {
        let start = state(route: .cloudKit, otherRoute: true)
        let (next, commands) = TransportFollowerPolicy.decide(.slotLost, state: start, now: base)
        XCTAssertEqual(commands, [.ignore])
        XCTAssertEqual(next, start)
    }

    func testHubOnRelayDropsEphemeral() {
        let (_, commands) = TransportFollowerPolicy.decide(.hubOnRelay(controlID: "c-1"), state: state(otherRoute: true), now: base)
        XCTAssertEqual(commands.suffix(2), [.dropEphemeral, .markHandled(controlID: "c-1")], "dropped before it is handled")
    }

    /// A plain follow to iCloud (the whole hub moved) drops nothing: resends still need the stored pairs.
    func testAPlainFollowToICloudKeepsStoredPairs() {
        let input = FollowerInput.switched(
            target: .cloudKit, epoch: 4, by: "phone-b", at: base, keyboxOpened: true, controlID: "c-2", on: .relay)
        let (_, commands) = TransportFollowerPolicy.decide(input, state: state(otherRoute: true), now: base)
        XCTAssertFalse(commands.contains(.dropEphemeral))
        XCTAssertTrue(commands.contains(.resendUnechoedOnNewTransport))
    }
}
