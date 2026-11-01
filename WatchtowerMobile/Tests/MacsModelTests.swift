import Foundation
import GRDB
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

    /// Review round 1 (F9): an unreadable registry row is listed at its own
    /// place, so a drag writes the order it shows: registry [X (unreadable),
    /// A, B], A dragged below B.
    func testADragOverAnUnreadableRowSavesTheShownOrder() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let registry = try HubRegistry(path: path)
        for hubID in ["hub-x", "hub-a", "hub-b"] {
            try registry.upsert(LinkRecord(
                hubID: hubID, macName: hubID, scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
                nonce: "n", dataShareURL: nil, relayShareURL: nil, deviceID: nil, linkedAt: nil
            ), now: Date(timeIntervalSince1970: 1_000))
        }
        try DatabaseQueue(path: path).write { db in
            try db.execute(sql: "UPDATE hubs SET link_json = ? WHERE hub_id = 'hub-x'", arguments: [Data("{not json".utf8)])
        }
        func items() throws -> [HubListItem] {
            HubListModel.items(
                rows: try registry.rows(), unreadable: try registry.unreadableHubIDs(), sessions: [:], activeHubID: nil, now: Date()
            )
        }
        XCTAssertEqual(try items().map(\.id), ["hub-x", "hub-a", "hub-b"], "the registry's order")

        let move = try XCTUnwrap(MacsModel.registryMove(try items(), from: [1], to: 3))
        try registry.move(move.hubID, to: move.index)

        XCTAssertEqual(try registry.hubIDs(), ["hub-x", "hub-b", "hub-a"])
        XCTAssertEqual(try items().map(\.id), try registry.hubIDs(), "the saved order is the shown one")
    }

    // MARK: - Finishing Relay links (relay client Phase 3 Task 10, mockup 7.4)

    private func promoted(_ state: PromotedLink.State, hubID: String = "hub-build") -> PromotedLink {
        var record = LinkRecord(
            hubID: hubID, macName: "build-box", scope: .private, ownerName: "", userRecordName: "", nonce: "n",
            dataShareURL: nil, relayShareURL: nil
        )
        record.setRelay(mac: String(repeating: "m", count: 52))
        return PromotedLink(link: record, slot: "slot-1", slotExpiresAt: Date(), state: state, since: Date())
    }

    func testEveryNeedsOwnerReasonHasItsRowCopyAndActions() {
        let expected: [PromotedLink.Reason: (String, [MacsModel.FinishingRow.Action])] = [
            .slotExpired: ("The link timed out on Relay. Try again, or cancel it.", [.tryAgain, .cancel]),
            .slotsFull: ("Relay already has 3 Macs. Remove one, then try again, or cancel this link.", [.manageMacs, .tryAgain, .cancel]),
            .replacementLimit: ("Too many Mac changes on Relay. Try again later, or cancel this link.", [.tryAgain, .cancel]),
            .notPaying: ("Relay isn't active on this iPhone. Try again when it is, or cancel this link.", [.tryAgain, .cancel]),
            .hubNotOnRelay: (
                "build-box isn't on Relay yet. Keep Watchtower open on it and try again, or cancel this link.", [.tryAgain, .cancel]
            ),
            .notConfirmed: ("Relay didn't confirm the link. Try again, or cancel it.", [.tryAgain, .cancel]),
            .updateApp: ("Update Watchtower to finish this link, or cancel it.", [.tryAgain, .cancel]),
            .tooManyMacs: ("You can link up to 4 Macs. Unlink one, then try again, or cancel this link.", [.tryAgain, .cancel])
        ]
        XCTAssertEqual(Set(expected.keys), Set(PromotedLink.Reason.allCases))
        for (reason, (line, actions)) in expected {
            let row = MacsModel.finishingRows([promoted(.needsOwner(reason))], running: [], failed: []).first
            XCTAssertEqual(row?.line, line, "\(reason)")
            XCTAssertEqual(row?.actions, actions, "\(reason)")
            XCTAssertNil(row?.note)
            XCTAssertEqual(row?.showsProgress, false)
        }
        XCTAssertEqual(MacsModel.FinishingRow.Action.manageMacs.title, "Manage Macs")
        XCTAssertEqual(MacsModel.FinishingRow.Action.tryAgain.title, "Try Again")
        XCTAssertEqual(MacsModel.FinishingRow.Action.cancel.title, "Cancel")
    }

    func testABusyRowHasNoActionsAndAFailedOneOffersTryAgain() {
        let link = promoted(.promoteSent)
        let busy = MacsModel.finishingRows([link], running: [link.hubID], failed: []).first
        XCTAssertEqual(busy?.status, .busy)
        XCTAssertEqual(busy?.line, "Finishing the link…")
        XCTAssertEqual(busy?.note, "No actions while an attempt runs.")
        XCTAssertEqual(busy?.showsProgress, true)
        XCTAssertEqual(busy?.actions, [])
        let failed = MacsModel.finishingRows([link], running: [], failed: [link.hubID]).first
        XCTAssertEqual(failed?.line, "Couldn't finish the link. Watchtower tries again when it opens.")
        XCTAssertEqual(failed?.actions, [.tryAgain, .cancel])
        let resting = MacsModel.finishingRows([link], running: [], failed: []).first
        XCTAssertEqual(resting?.status, .finishing)
        XCTAssertEqual(resting?.line, "Finishing the link…")
        XCTAssertTrue(failed?.toneUses.allSatisfy { $0.tone != .orange } ?? false)
    }

    func testTheCancelConfirmationCopy() {
        XCTAssertEqual(MacsModel.cancelQuestion("build-box"), "Cancel the link to build-box? It frees its Relay slot.")
        XCTAssertEqual(MacsModel.cancelLink, "Cancel Link")
        XCTAssertEqual(MacsModel.keepTrying, "Keep Trying")
    }
}
