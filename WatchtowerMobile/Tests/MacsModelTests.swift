import Foundation
import XCTest
@testable import WatchtowerMobile

/// Settings → Macs' decisions (multi-hub spec §5.6): one destructive action
/// per row, its confirmation copy, and the move's registry index.
@MainActor
final class MacsModelTests: XCTestCase {
    private func item(removed: Bool = false, unopened: Bool = false, canForget: Bool = false, isActive: Bool = false) -> HubListItem {
        HubListItem(
            id: "hub-acme", name: "Acme Mac", flavor: nil, online: false, offlineDays: nil, openAsks: 0,
            isActive: isActive, removedByMac: removed, unopened: unopened, canForget: canForget, problem: nil
        )
    }

    func testOneActionPerRow() {
        XCTAssertEqual(MacsModel.action(for: item()), .unlink, "a healthy linked Mac")
        XCTAssertEqual(MacsModel.action(for: item(canForget: true)), .forget, "long offline")
        XCTAssertEqual(MacsModel.action(for: item(removed: true, canForget: true)), .forget, "removed by the Mac")
    }

    func testConfirmationCopy() {
        let unlink = MacsModel.Ask(action: .unlink, item: item())
        XCTAssertEqual(unlink.title, "Unlink Acme Mac?")
        XCTAssertEqual(unlink.button, "Unlink")
        XCTAssertEqual(unlink.message, "This phone forgets the Mac's data. Changes still waiting for the Mac are not sent.")
        let removed = MacsModel.Ask(action: .forget, item: item(removed: true, canForget: true))
        XCTAssertEqual(removed.title, "Forget Acme Mac?")
        XCTAssertEqual(removed.button, "Forget")
        XCTAssertEqual(removed.message, "Its data on this iPhone is deleted.")
        let offline = MacsModel.Ask(action: .forget, item: item(canForget: true))
        XCTAssertEqual(offline.message, "This unlinks the Mac and deletes its data on this iPhone.")
    }

    /// A Mac whose data could not be opened at launch is listed with its
    /// problem and offers Forget only (spec §6.3).
    func testAnUnopenedMacIsListedWithItsProblemAndOffersForget() throws {
        let rows = [
            HubRow(
                link: LinkRecord(
                    hubID: "hub-acme", macName: "Acme Mac", scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
                    nonce: "nonce-acme", dataShareURL: nil, relayShareURL: nil, deviceID: "device-acme-1", linkedAt: nil
                ),
                flavor: nil, sortOrder: 0, state: .linked, grantMissingSince: nil,
                lastHeartbeatAt: Date(), linkedOn: Date()
            )
        ]

        let items = HubListModel.items(rows: rows, sessions: [:], unopened: ["hub-acme"], activeHubID: nil, now: Date())

        let broken = try XCTUnwrap(items.first)
        XCTAssertTrue(broken.unopened)
        XCTAssertEqual(broken.problem, "Couldn't open this Mac's data on this iPhone")
        XCTAssertTrue(broken.canForget, "online by its last heartbeat, but nothing else can be done with it")
        XCTAssertEqual(MacsModel.action(for: broken), .forget)
        XCTAssertEqual(
            HubListModel.items(rows: rows, sessions: [:], activeHubID: nil, now: Date()).first?.unopened, false,
            "a row is unopened only when the boot said so"
        )
    }

    /// Settings' button for the Mac on screen is its Macs row's action, with
    /// the same copy: Forget for a Mac that removed this phone, never an
    /// "Unlink" that behaves like Forget.
    func testSettingsOffersTheSameActionAsTheMacsRow() {
        let removed = SettingsView.removalAsk(for: item(removed: true, canForget: true, isActive: true))
        XCTAssertEqual(removed?.action, .forget)
        XCTAssertEqual(removed?.button, "Forget")
        XCTAssertEqual(removed?.title, "Forget Acme Mac?")
        XCTAssertEqual(removed?.message, "Its data on this iPhone is deleted.")

        let healthy = SettingsView.removalAsk(for: item(isActive: true))
        XCTAssertEqual(healthy?.action, .unlink)
        XCTAssertEqual(healthy?.title, "Unlink Acme Mac?")

        XCTAssertEqual(SettingsView.removalAsk(for: item(canForget: true, isActive: true))?.action, .forget, "long offline")
        XCTAssertNil(SettingsView.removalAsk(for: nil))
    }

    func testMoveIndexMath() {
        XCTAssertEqual(MacsModel.targetIndex(from: 2, destination: 0), 0, "up")
        XCTAssertEqual(MacsModel.targetIndex(from: 0, destination: 3), 2, "down: the offset counts the row itself")
        XCTAssertNil(MacsModel.targetIndex(from: 1, destination: 1), "dropped where it was")
        XCTAssertNil(MacsModel.targetIndex(from: 1, destination: 2), "just below itself")
    }
}
