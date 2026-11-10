import Foundation
import WatchtowerE2ETesting
@testable import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone left behind (relay client Phase 5, Task 17, ask #1081), over the live `AppRoot` and `Bed`: a relay-only link
/// that reads its Mac's move to iCloud keeps its route, merges no keybox, withdraws and lists, and marks `macMoved`; only
/// a marker toward the relay in a later epoch clears it.
@MainActor
final class MacMovedWiringTests: XCTestCase {
    private let hubID = TestE2E.hubID.uuidString

    private func switched(to target: TransportKind, epoch: UInt32, keybox: String? = nil) -> ControlPayload {
        ControlPayload(
            id: UUID().uuidString, kind: .transportSwitched, deviceID: TestE2E.deviceID.uuidString, hubID: hubID,
            epoch: epoch, target: target.rawValue, by: "another-phone", at: Bed.switchedAt, keybox: keybox)
    }

    private func marker(_ target: TransportKind, epoch: UInt32) -> TransportMarker {
        TransportMarker(target: target, epoch: epoch, by: "another-phone", at: Bed.switchedAt)
    }

    private func keybox(_ bed: Bed, epoch: UInt32) async {
        let grant = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: hubID, name: "Colleague A's iPhone", scope: .private,
            linked: true, typingAllowed: true, startSessionsAllowed: true, orderedActions: 1)
        await bed.root.linking.reconcileKeyboxKeys(hubID: hubID, keybox: Keybox(grant: grant, keys: TestPhone.keyboxKeys(epoch: epoch)))
    }

    /// A move made by another phone brings no `relayLapsed`: the switch read withdraws and lists, by control and by marker.
    func testAMoveReadOnARelayOnlyLinkListsUnechoed() async throws {
        for byMarker in [false, true] {
            let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
            let session = try await bed.orderedSession()
            try await bed.sendTwoActions(session)
            let before = Set(try await bed.relayMailbox().map(\.name))

            let decided = byMarker
                ? await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
                : await session.transportSignals.control(switched(to: .cloudKit, epoch: 2))

            XCTAssertTrue(decided)
            let listed = try session.store.pendingActions().filter { $0.delivery == .undelivered }
            XCTAssertEqual(Set(listed.map(\.undeliveredReason)), [.refused], "by marker: \(byMarker)")
            XCTAssertEqual(listed.count, 2)
            let after = Set(try await bed.relayMailbox().map(\.name))
            XCTAssertEqual(before.subtracting(after).count, 2, "both withdrawn")
            XCTAssertEqual(try bed.row()?.link.macMoved, 2)
            XCTAssertNil(try bed.row()?.link.relayRefused, "a move starts no term")
            XCTAssertFalse(session.waitsForKeybox, "no key source")
        }
    }

    func testAMarkerTowardICloudOnARelayOnlyLinkDoesNotMoveTheRoute() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        let epochs = try bed.keys.hubLink(hubID)?.epochs.map(\.epoch)
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertNil(bed.root.routeMoves[hubID], "no session move")
        XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), epochs, "no epoch adopted")
    }

    func testTheSwitchNoticesKeyboxIsNotMergedOnARelayOnlyLink() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        let control = try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay)
        XCTAssertNotNil(control.keybox)
        let decided = await session.transportSignals.control(control)
        XCTAssertTrue(decided, "marked handled")
        XCTAssertFalse(try XCTUnwrap(try bed.keys.hubLink(hubID)).epochs.contains { $0.epoch == 2 }, "the keybox was not merged")
        XCTAssertTrue(try XCTUnwrap(try bed.keys.hubLink(hubID)).hasEphemeralState, "no key erased")
        XCTAssertEqual(try bed.row()?.link.macMoved, 2)
    }

    /// The zone keybox of the relay's new epoch merged first, then the marker toward the relay in that epoch.
    func testAMarkerTowardTheRelayClearsMacMoved() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        XCTAssertFalse(session.waitsForKeybox)
        await keybox(bed, epoch: 3)

        _ = await session.transportSignals.marker(marker(.relay, epoch: 3))

        XCTAssertNil(try bed.row()?.link.macMoved)
        XCTAssertTrue(session.waitsForKeybox, "the key source is back")
    }

    func testAStaleKeyboxDoesNotClearMacMoved() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        await keybox(bed, epoch: 1)
        await keybox(bed, epoch: 3)
        XCTAssertEqual(try bed.row()?.link.macMoved, 2, "a merge clears nothing")
    }

    /// The old marker toward the relay, or a `transport_switched{relay}`, clears nothing.
    func testAnOldEchoClearsNothing() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        _ = await session.transportSignals.marker(marker(.relay, epoch: 1))
        _ = await session.transportSignals.marker(marker(.relay, epoch: 2))
        _ = await session.transportSignals.control(switched(to: .relay, epoch: 3))
        XCTAssertEqual(try bed.row()?.link.macMoved, 2)
    }

    /// The flag survives a relaunch and keeps the key source off.
    func testMacMovedSurvivesARelaunch() async throws {
        let bed = try await Bed.make(self, on: .relay, hubTransports: ["relay"])
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        try await bed.relaunch(self)
        XCTAssertEqual(try bed.row()?.link.macMoved, 2)
        XCTAssertFalse(try bed.session().waitsForKeybox)
    }

    /// A link with an iCloud route follows the move as before: no mark.
    func testARoutedLinkFollowsAndIsNotMarked() async throws {
        let bed = try await Bed.make(self, on: .relay)
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        try await bed.root.routeMoves[hubID]?.value(within: 60, "bed.root.routeMoves[hubID]")
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.macMoved)
    }
}
