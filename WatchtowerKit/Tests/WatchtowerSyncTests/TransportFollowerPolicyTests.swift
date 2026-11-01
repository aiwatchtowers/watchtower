import Foundation
import WatchtowerSync
import XCTest

/// `TransportFollowerPolicy` (relay client Phase 3, Task 7): the phone's switch decisions (sim rules 12, 12a, 13, 15
/// and ruling R32) as one pure function. `RelaySimSwitchTwins` runs the same function inside `SimPhone`.
final class TransportFollowerPolicyTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(
        route: TransportKind = .relay, epoch: UInt32 = 1, canUseRelay: RelayUse = .yes
    ) -> FollowerState {
        FollowerState(route: route, newestEpoch: epoch, canUseRelay: canUseRelay)
    }

    private func switched(
        to target: TransportKind, epoch: UInt32, keyboxOpened: Bool = true, id: String = "c-1", on: TransportKind = .cloudKit
    ) -> FollowerInput {
        .switched(target: target, epoch: epoch, by: "phone-a", at: base, keyboxOpened: keyboxOpened, controlID: id, on: on)
    }

    func testASwitchMovesResendsAndAcks() {
        let (next, commands) = TransportFollowerPolicy.decide(switched(to: .cloudKit, epoch: 2), state: state(), now: base)
        XCTAssertEqual(commands, [
            .mergeKeybox,
            .moveRoute(to: .cloudKit, epoch: 2, by: "phone-a", at: base),
            .resendUnechoedOnNewTransport,
            .sendEpochAck(2),
            .drainMailbox(on: .relay),
            .markHandled(controlID: "c-1")
        ])
        XCTAssertEqual(next.route, .cloudKit)
        XCTAssertEqual(next.newestEpoch, 2)
        XCTAssertEqual(next.leftTransport, .relay, "the relay mailbox is still to drain")
    }

    func testASwitchOnTheSameRouteAdoptsTheEpochWithoutMoving() {
        let (next, commands) = TransportFollowerPolicy.decide(switched(to: .relay, epoch: 3), state: state(), now: base)
        XCTAssertEqual(commands, [
            .mergeKeybox,
            .moveRoute(to: .relay, epoch: 3, by: "phone-a", at: base),
            .sendEpochAck(3),
            .markHandled(controlID: "c-1")
        ])
        XCTAssertEqual(next.route, .relay)
        XCTAssertNil(next.leftTransport)
    }

    func testAnOlderOrEqualEpochIsOnlyHandled() {
        let start = state(route: .cloudKit, epoch: 4)
        for epoch: UInt32 in [3, 4] {
            let (next, commands) = TransportFollowerPolicy.decide(switched(to: .relay, epoch: epoch), state: start, now: base)
            XCTAssertEqual(commands, [.markHandled(controlID: "c-1")], "epoch \(epoch)")
            XCTAssertEqual(next, start, "epoch \(epoch)")
        }
    }

    func testASecondCopyIsARepeat() {
        let (afterFirst, _) = TransportFollowerPolicy.decide(
            switched(to: .cloudKit, epoch: 2, on: .cloudKit), state: state(), now: base)
        let (afterSecond, commands) = TransportFollowerPolicy.decide(
            switched(to: .cloudKit, epoch: 2, on: .relay), state: afterFirst, now: base)
        XCTAssertEqual(commands, [.requestAnswered, .markHandled(controlID: "c-1")], "nothing moves twice")
        XCTAssertEqual(afterSecond, afterFirst)
    }

    func testTheCurrentRouteInTheCurrentEpochAnswersTheRequest() {
        // The hub's answer to a request for the transport it is already on (Go `handleSwitch`, `target == current`).
        let start = state(route: .relay, epoch: 3)
        let (next, commands) = TransportFollowerPolicy.decide(switched(to: .relay, epoch: 3), state: start, now: base)
        XCTAssertEqual(commands, [.requestAnswered, .markHandled(controlID: "c-1")])
        XCTAssertEqual(next, start)
        // The same epoch naming another route is only a stale copy.
        XCTAssertEqual(
            TransportFollowerPolicy.decide(switched(to: .cloudKit, epoch: 3), state: start, now: base).commands,
            [.markHandled(controlID: "c-1")])
    }

    func testSwitchToRelayOnAFreePhoneActsAsHubOnRelay() {
        let start = state(route: .cloudKit, epoch: 2, canUseRelay: .no)
        let (next, commands) = TransportFollowerPolicy.decide(switched(to: .relay, epoch: 3), state: start, now: base)
        XCTAssertEqual(commands, [.listUnechoedAsUndelivered, .markHandled(controlID: "c-1")])
        XCTAssertEqual(next, start, "no route move, no epoch adopted")

        let (_, viaHub) = TransportFollowerPolicy.decide(.hubOnRelay(controlID: "c-1"), state: start, now: base)
        XCTAssertEqual(commands, viaHub, "the same answer as hub_on_relay")
    }

    func testUnknownPayingDecidesNothingAndKeepsTheControl() {
        let start = state(route: .cloudKit, epoch: 2, canUseRelay: .unknown)
        for input in [switched(to: .relay, epoch: 3), .hubOnRelay(controlID: "c-1")] {
            let (next, commands) = TransportFollowerPolicy.decide(input, state: start, now: base)
            XCTAssertEqual(commands, [], "\(input): no command, no markHandled")
            XCTAssertEqual(next, start)
        }
        let marker = FollowerInput.marker(target: .relay, epoch: 3, by: "phone-a", at: base, on: .cloudKit)
        XCTAssertEqual(TransportFollowerPolicy.decide(marker, state: start, now: base).commands, [])
    }

    func testHubOnRelayListsUnechoedAsUndelivered() {
        // A lapsed phone still on the relay goes to CloudKit and drains what it left behind.
        let start = state(route: .relay, epoch: 2, canUseRelay: .no)
        let (next, commands) = TransportFollowerPolicy.decide(.hubOnRelay(controlID: "c-9"), state: start, now: base)
        XCTAssertEqual(commands, [
            .moveRoute(to: .cloudKit, epoch: 2, by: "", at: base),
            .listUnechoedAsUndelivered,
            .drainMailbox(on: .relay),
            .markHandled(controlID: "c-9")
        ])
        XCTAssertEqual(next.route, .cloudKit)
        XCTAssertEqual(next.newestEpoch, 2)
        XCTAssertEqual(next.leftTransport, .relay)

        // A phone already on CloudKit only lists.
        let free = state(route: .cloudKit, epoch: 2, canUseRelay: .no)
        let (stayed, listed) = TransportFollowerPolicy.decide(.hubOnRelay(controlID: "c-9"), state: free, now: base)
        XCTAssertEqual(listed, [.listUnechoedAsUndelivered, .markHandled(controlID: "c-9")])
        XCTAssertEqual(stayed, free)

    }

    func testHubOnRelayIsObeyedEvenByAPayingPhone() {
        // The hub knows the lapse before the phone does (Go `hubWithoutUs` always obeys): never deleted unacted.
        let paying = state(route: .relay, epoch: 2, canUseRelay: .yes)
        let (next, commands) = TransportFollowerPolicy.decide(.hubOnRelay(controlID: "c-9"), state: paying, now: base)
        XCTAssertEqual(commands, [
            .moveRoute(to: .cloudKit, epoch: 2, by: "", at: base),
            .listUnechoedAsUndelivered,
            .drainMailbox(on: .relay),
            .markHandled(controlID: "c-9")
        ])
        XCTAssertEqual(next.route, .cloudKit)
        XCTAssertEqual(next.canUseRelay, .yes, "the paying answer stays the entitlement's")
    }

    func testAMarkerNewerThanTheEpochIsFollowed() {
        let marker = FollowerInput.marker(target: .cloudKit, epoch: 3, by: "phone-b", at: base, on: .relay)
        let (next, commands) = TransportFollowerPolicy.decide(marker, state: state(), now: base)
        XCTAssertEqual(commands, [
            .moveRoute(to: .cloudKit, epoch: 3, by: "phone-b", at: base),
            .resendUnechoedOnNewTransport,
            .sendEpochAck(3),
            .drainMailbox(on: .relay)
        ], "no keybox merge: the keybox is read on the new route's data zone")
        XCTAssertEqual(next.route, .cloudKit)
        XCTAssertEqual(next.newestEpoch, 3)
    }

    func testAMarkerIsNeverFollowedBackwards() {
        let start = state(route: .cloudKit, epoch: 5)
        for epoch: UInt32 in [4, 5] {
            let marker = FollowerInput.marker(target: .relay, epoch: epoch, by: "phone-b", at: base, on: .relay)
            let (next, commands) = TransportFollowerPolicy.decide(marker, state: start, now: base)
            XCTAssertEqual(commands, [.ignore], "epoch \(epoch)")
            XCTAssertEqual(next, start)
        }
    }

    func testAnUnopenedKeyboxMovesNothing() {
        let start = state()
        let (next, commands) = TransportFollowerPolicy.decide(
            switched(to: .cloudKit, epoch: 2, keyboxOpened: false), state: start, now: base)
        XCTAssertEqual(commands, [], "left unhandled: retried on the next pass")
        XCTAssertEqual(next, start)
        // The marker recovers it.
        let marker = FollowerInput.marker(target: .cloudKit, epoch: 2, by: "phone-a", at: base, on: .relay)
        XCTAssertEqual(TransportFollowerPolicy.decide(marker, state: next, now: base).state.route, .cloudKit)
    }

    func testRelayUnreachableSixtySecondsPollsCloudKit() {
        var current = state()
        func tick(_ seconds: TimeInterval) -> [FollowerCommand] {
            let now = base.addingTimeInterval(seconds)
            let result = TransportFollowerPolicy.decide(.relayReachable(false, at: now), state: current, now: now)
            current = result.state
            return result.commands
        }
        XCTAssertEqual(tick(0), [])
        XCTAssertEqual(current.relayUnreachableSince, base)
        XCTAssertEqual(tick(30), [])
        XCTAssertEqual(tick(60), [], "not past 60 s yet")
        XCTAssertEqual(tick(61), [.pollOtherMailbox(on: .cloudKit)])
        XCTAssertEqual(tick(75), [], "every 30 s, not every pass")
        XCTAssertEqual(tick(91), [.pollOtherMailbox(on: .cloudKit)])
        XCTAssertEqual(current.relayUnreachableSince, base, "the outage keeps its start")

        // On CloudKit an unreachable relay is no reason to poll anything.
        var onCloudKit = state(route: .cloudKit)
        onCloudKit.relayUnreachableSince = base
        let later = base.addingTimeInterval(120)
        XCTAssertEqual(
            TransportFollowerPolicy.decide(.relayReachable(false, at: later), state: onCloudKit, now: later).commands, [])
    }

    func testReachableAgainStopsThePoll() {
        var current = state()
        current.relayUnreachableSince = base
        let back = base.addingTimeInterval(70)
        current = TransportFollowerPolicy.decide(.relayReachable(true, at: back), state: current, now: back).state
        XCTAssertNil(current.relayUnreachableSince)
        let after = back.addingTimeInterval(31)
        let (next, commands) = TransportFollowerPolicy.decide(.relayReachable(false, at: after), state: current, now: after)
        XCTAssertEqual(commands, [], "a new outage starts its own 60 s")
        XCTAssertEqual(next.relayUnreachableSince, after)
    }

    func testADrainedMailboxIsForgotten() {
        var current = state(route: .cloudKit)
        current.leftTransport = .relay
        XCTAssertEqual(TransportFollowerPolicy.decide(.oldMailboxDrained(.cloudKit), state: current, now: base).state, current)
        let (next, commands) = TransportFollowerPolicy.decide(.oldMailboxDrained(.relay), state: current, now: base)
        XCTAssertEqual(commands, [])
        XCTAssertNil(next.leftTransport)
    }
}
