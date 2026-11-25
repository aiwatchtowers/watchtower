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
        await bed.root.routeMoves[hubID]?.value
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.macMoved)
    }

    // MARK: - A link made over Relay follows only on the Mac owner's Apple ID (#2381)

    /// The phone's Apple ID is the Mac owner's: it follows the Mac to iCloud, by marker and by `transport_switched`.
    func testARelayMadeLinkOnTheOwnersAppleIDFollowsTheMacToICloud() async throws {
        for byMarker in [false, true] {
            let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
            let session = try await bed.orderedSession()
            let asks = bed.access.accountAsks

            let decided = byMarker
                ? await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
                : await session.transportSignals.control(try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay))
            await bed.root.routeMoves[hubID]?.value

            XCTAssertTrue(decided, "by marker: \(byMarker)")
            XCTAssertGreaterThan(bed.access.accountAsks, asks, "the phone's account was read")
            XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
            XCTAssertNil(try bed.row()?.link.macMoved)
            XCTAssertEqual(try bed.row()?.link.userRecordName, "", "the account is not written into the link")
        }
    }

    /// Another Apple ID would open its own private database: the link stays on the relay, left behind (S59).
    func testARelayMadeLinkOnAnotherAppleIDStaysOnTheRelay() async throws {
        for byMarker in [false, true] {
            let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
            bed.access.userRecordNameValue = "_another-acme"
            let session = try await bed.orderedSession()
            let epochs = try bed.keys.hubLink(hubID)?.epochs.map(\.epoch)

            let decided = byMarker
                ? await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
                : await session.transportSignals.control(try await bed.writeSwitch(target: .cloudKit, epoch: 2, on: .relay))

            XCTAssertTrue(decided, "by marker: \(byMarker)")
            XCTAssertEqual(try bed.row()?.link.transport, .relay)
            XCTAssertNil(bed.root.routeMoves[hubID], "no session move")
            XCTAssertEqual(try bed.row()?.link.macMoved, 2, "S59")
            XCTAssertEqual(try bed.keys.hubLink(hubID)?.epochs.map(\.epoch), epochs, "no epoch adopted")
        }
    }

    /// An account that cannot be read moves nothing and decides nothing; the marker handed again once it reads follows.
    func testARelayMadeLinkWithAnUnknownAccountDoesNotMove() async throws {
        let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        bed.access.status = .noAccount
        let session = try await bed.orderedSession()

        let decided = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))

        XCTAssertFalse(decided, "left for a later pass")
        XCTAssertEqual(try bed.row()?.link.transport, .relay)
        XCTAssertNil(bed.root.routeMoves[hubID], "no session move")
        XCTAssertNil(try bed.row()?.link.macMoved, "not left behind either")

        bed.access.status = .available
        let again = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        await bed.root.routeMoves[hubID]?.value
        XCTAssertTrue(again)
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit, "the owner's account follows once read")
    }

    /// A link made over iCloud carries its own account: it follows whatever account the phone reads now.
    func testAnICloudMadeLinkFollowsWithoutTheAccountCheck() async throws {
        let bed = try await Bed.make(self, on: .relay)
        bed.access.userRecordNameValue = "_another-acme"
        let session = try await bed.orderedSession()
        let asks = bed.access.accountAsks

        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.macMoved)
        XCTAssertEqual(bed.access.accountAsks, asks, "no account read")
    }
}

/// #2381, round 1 of review: the edges of the account check.
extension MacMovedWiringTests {
    /// A Mac already on Relay issues a code with no owner: the phone cannot tell and follows as before.
    func testARelayMadeLinkWithNoOwnerFollowsWithoutTheAccountCheck() async throws {
        let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "")
        bed.access.userRecordNameValue = "_another-acme"
        let session = try await bed.orderedSession()
        let asks = bed.access.accountAsks

        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.macMoved)
        XCTAssertEqual(bed.access.accountAsks, asks, "no account read")
    }

    /// The link left behind on another account ends its open request toward iCloud: the Mac moved without it.
    func testALeftBehindMoveClearsAnOpenRequest() async throws {
        let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        bed.access.userRecordNameValue = "_another-acme"
        let session = try await bed.orderedSession()
        var link = try XCTUnwrap(try bed.row()?.link)
        link.transportRequest = TransportRequestRecord(target: .cloudKit, controlID: "C", reason: nil, at: Bed.switchedAt)
        XCTAssertTrue(bed.root.persistRoute(link))

        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))

        XCTAssertEqual(try bed.row()?.link.macMoved, 2)
        XCTAssertNil(try bed.row()?.link.transportRequest)
    }

    /// A move marked while the phone was on another account ends when the owner's account follows the next one.
    func testTheOwnersFollowClearsAStaleMacMoved() async throws {
        let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        bed.access.userRecordNameValue = "_another-acme"
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        XCTAssertEqual(try bed.row()?.link.macMoved, 2)

        bed.access.userRecordNameValue = "_owner-acme"
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 3))
        await bed.root.routeMoves[hubID]?.value

        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        XCTAssertNil(try bed.row()?.link.macMoved)
    }

    /// A newer `transport_switched{cloudkit}` whose keybox does not open: another account is left behind at once, the
    /// owner's waits for a keybox it can follow with.
    func testASwitchWithoutItsKeyboxDecidesByTheAccount() async throws {
        let other = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        other.access.userRecordNameValue = "_another-acme"
        let left = try await other.orderedSession()
        let decided = await left.transportSignals.control(switched(to: .cloudKit, epoch: 2))
        XCTAssertTrue(decided)
        XCTAssertEqual(try other.row()?.link.transport, .relay)
        XCTAssertEqual(try other.row()?.link.macMoved, 2)

        let owner = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        let session = try await owner.orderedSession()
        let waits = await session.transportSignals.control(switched(to: .cloudKit, epoch: 2))
        XCTAssertFalse(waits, "left for a later pass")
        XCTAssertEqual(try owner.row()?.link.transport, .relay)
        XCTAssertNil(try owner.row()?.link.macMoved)
    }

    /// A lost slot: the owner's account moves to iCloud; another starts the term (`.slot`); a failed read decides nothing.
    func testALostSlotDecidesByTheAccount() async throws {
        let owner = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        let moving = try await owner.orderedSession()
        await moving.relaySlotLost()
        await owner.root.routeMoves[hubID]?.value
        XCTAssertEqual(try owner.row()?.link.transport, .cloudKit)
        XCTAssertNil(try owner.row()?.link.relayRefused)

        let other = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        other.access.userRecordNameValue = "_another-acme"
        await (try await other.orderedSession()).relaySlotLost()
        XCTAssertEqual(try other.row()?.link.transport, .relay)
        XCTAssertEqual(try other.row()?.link.relayRefused?.cause, .slot)

        let unknown = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        unknown.access.identityError = CocoaError(.featureUnsupported)
        await (try await unknown.orderedSession()).relaySlotLost()
        XCTAssertEqual(try unknown.row()?.link.transport, .relay)
        XCTAssertNil(try unknown.row()?.link.relayRefused)
        XCTAssertNil(unknown.root.routeMoves[hubID], "no session move")
    }

    /// After the owner's follow the link is on iCloud with no account of its own: an account check counts it as the
    /// owner's, so it and another iCloud hub stay; a really changed account still ends them.
    func testAnOwnerFollowedLinkSurvivesTheAccountCheck() async throws {
        let bed = try await Bed.make(self, on: .relay, relayLinkOwner: "_owner-acme")
        let session = try await bed.orderedSession()
        _ = await session.transportSignals.marker(marker(.cloudKit, epoch: 2))
        await bed.root.routeMoves[hubID]?.value
        XCTAssertEqual(try bed.row()?.link.transport, .cloudKit)
        let home = UUID().uuidString
        try bed.registry.upsert(LinkRecord(
            hubID: home, macName: "Home Mac", scope: .private, ownerName: "", userRecordName: "_owner-acme",
            nonce: "nonce-home", dataShareURL: nil, relayShareURL: nil, deviceID: TestE2E.deviceID.uuidString,
            linkedAt: Date(timeIntervalSince1970: 1_700_000_000)), now: Date())

        await bed.root.linking.accountChanged()

        XCTAssertNotNil(try bed.row(), "the followed link stays")
        XCTAssertNotNil(try bed.registry.row(home), "the other iCloud hub stays")

        bed.access.userRecordNameValue = "_another-acme"
        await bed.root.linking.accountChanged()
        XCTAssertNil(try bed.row())
        XCTAssertNil(try bed.registry.row(home))
    }
}
