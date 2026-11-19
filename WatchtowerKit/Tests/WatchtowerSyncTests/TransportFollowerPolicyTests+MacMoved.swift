import Foundation
import WatchtowerSync
import XCTest

/// The phone left behind (relay client Phase 5, Task 17, ask #1081): a relay-only link that reads its Mac's move to
/// iCloud cannot follow. It withdraws and lists its unechoed actions, keeps its route, merges no keybox and marks the
/// move (S59); only a marker toward the relay in a later epoch clears it.
final class TransportFollowerPolicyMacMovedTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func state(otherRoute: Bool = false, moved: UInt32? = nil) -> FollowerState {
        FollowerState(route: .relay, newestEpoch: 3, canUseRelay: .yes, hasOtherRoute: otherRoute, macMovedEpoch: moved)
    }

    private func switched(_ target: TransportKind, epoch: UInt32) -> FollowerInput {
        .switched(target: target, epoch: epoch, by: "another-phone", at: base, keyboxOpened: true, controlID: "c-1", on: .relay)
    }

    private func marker(_ target: TransportKind, epoch: UInt32) -> FollowerInput {
        .marker(target: target, epoch: epoch, by: "another-phone", at: base, on: .relay)
    }

    func testAMarkerTowardICloudOnARelayOnlyLinkDoesNotMoveTheRoute() {
        let (next, commands) = TransportFollowerPolicy.decide(marker(.cloudKit, epoch: 4), state: state(), now: base)
        XCTAssertEqual(next.route, .relay, "the route stays: a relay-only link has nowhere to go")
        XCTAssertEqual(next.newestEpoch, 3, "the epoch is not adopted")
        XCTAssertFalse(commands.contains { if case .moveRoute = $0 { true } else { false } })
        XCTAssertFalse(commands.contains(.sendEpochAck(4)))
        XCTAssertTrue(commands.contains(.markMoved(epoch: 4)))
    }

    /// A move made by another phone brings no `relayLapsed`: the move read is what withdraws and lists.
    func testAMoveReadOnARelayOnlyLinkListsUnechoed() {
        let (_, bySwitch) = TransportFollowerPolicy.decide(switched(.cloudKit, epoch: 4), state: state(), now: base)
        XCTAssertEqual(bySwitch, [.withdrawUnechoed, .markMoved(epoch: 4), .markHandled(controlID: "c-1")])
        let (_, byMarker) = TransportFollowerPolicy.decide(marker(.cloudKit, epoch: 4), state: state(), now: base)
        XCTAssertEqual(byMarker, [.withdrawUnechoed, .markMoved(epoch: 4)])
    }

    func testTheSwitchNoticesKeyboxIsNotMergedOnARelayOnlyLink() {
        let (_, commands) = TransportFollowerPolicy.decide(switched(.cloudKit, epoch: 4), state: state(), now: base)
        XCTAssertFalse(commands.contains(.mergeKeybox), "it cannot follow, so it merges nothing")
        XCTAssertFalse(commands.contains(.dropEphemeral), "no key is erased")
    }

    /// Read again on every pass, the same move marks nothing new and withdraws nothing again.
    func testAMoveReadAgainChangesNothing() {
        let (_, marker) = TransportFollowerPolicy.decide(marker(.cloudKit, epoch: 4), state: state(moved: 4), now: base)
        XCTAssertEqual(marker, [.ignore])
        let (_, control) = TransportFollowerPolicy.decide(switched(.cloudKit, epoch: 4), state: state(moved: 4), now: base)
        XCTAssertEqual(control, [.markHandled(controlID: "c-1")])
    }

    /// With an iCloud route the phone follows, as before.
    func testAMoveWithARouteFollowsAsBefore() {
        let (next, commands) = TransportFollowerPolicy.decide(switched(.cloudKit, epoch: 4), state: state(otherRoute: true), now: base)
        XCTAssertEqual(next.route, .cloudKit)
        XCTAssertTrue(commands.contains(.mergeKeybox))
        XCTAssertFalse(commands.contains(.markMoved(epoch: 4)))
    }

    /// The zone keybox merged first has already raised the epoch, so the marker's epoch is not above the newest.
    func testAMarkerTowardTheRelayClearsMacMoved() {
        let back = FollowerState(route: .relay, newestEpoch: 5, canUseRelay: .yes, hasOtherRoute: false, macMovedEpoch: 4)
        let (_, commands) = TransportFollowerPolicy.decide(marker(.relay, epoch: 5), state: back, now: base)
        XCTAssertEqual(commands, [.clearMoved, .ignore])
    }

    /// A marker toward the relay from before the move (or the move's own epoch) clears nothing, nor does a
    /// `transport_switched{relay}`.
    func testAnOldEchoClearsNothing() {
        for epoch: UInt32 in [3, 4] {
            let (_, commands) = TransportFollowerPolicy.decide(marker(.relay, epoch: epoch), state: state(moved: 4), now: base)
            XCTAssertFalse(commands.contains(.clearMoved), "epoch \(epoch)")
        }
        let (_, control) = TransportFollowerPolicy.decide(switched(.relay, epoch: 5), state: state(moved: 4), now: base)
        XCTAssertFalse(control.contains(.clearMoved))
    }
}
