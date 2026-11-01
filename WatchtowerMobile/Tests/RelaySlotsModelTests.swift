import Foundation
import XCTest
@testable import WatchtowerMobile

/// The three-slots screen's copy and states (relay client Phase 3 Task 10, mockup 7.3).
final class RelaySlotsModelTests: XCTestCase {
    private let linkedMac = String(repeating: "a", count: 52)
    private let finishingMac = String(repeating: "b", count: 52)
    private let unknownMac = String(repeating: "c", count: 52)

    private func linkedRow() -> HubRow {
        var record = LinkRecord(
            hubID: "hub-work", macName: "Work Mac", scope: .private, ownerName: "", userRecordName: "", nonce: "n",
            dataShareURL: nil, relayShareURL: nil
        )
        record.setRelay(mac: linkedMac)
        return HubRow(
            link: record, flavor: nil, sortOrder: 0, state: .linked, grantMissingSince: nil, lastHeartbeatAt: nil,
            linkedOn: Date()
        )
    }

    private func finishing() -> PromotedLink {
        var record = LinkRecord(
            hubID: "hub-build", macName: "build-box", scope: .private, ownerName: "", userRecordName: "", nonce: "n",
            dataShareURL: nil, relayShareURL: nil
        )
        record.setRelay(mac: finishingMac)
        return PromotedLink(link: record, slot: "slot-1", slotExpiresAt: Date(), state: .confirmed, since: Date())
    }

    private func model(_ state: RelaySlotsState) -> RelaySlotsModel {
        RelaySlotsModel(state: state, links: [linkedRow()], promoted: [finishing()])
    }

    func testTheScreenNamesEachMacAndOffersRemove() {
        let screen = model(RelaySlotsState(macs: [linkedMac, unknownMac, finishingMac]))
        XCTAssertEqual(screen.title, "Your subscription already has 3 Macs. Remove one to add this Mac over Relay.")
        XCTAssertEqual(screen.rows.map(\.name), ["Work Mac", "A Mac not on this iPhone", "build-box"])
        XCTAssertEqual(screen.rows.map(\.sub), [nil, nil, "Finishing link"])
        XCTAssertEqual(screen.rows.map(\.kind), [.linkedHere(hubID: "hub-work"), .unknown, .finishing(hubID: "hub-build")])
        XCTAssertEqual(screen.rows.map(\.action.title), ["Remove", "Remove", "Remove"])
        XCTAssertEqual(screen.footnote, "Up to 5 replacements in 30 days.")
        XCTAssertEqual(RelaySlotsModel.navigationTitle, "Add Mac")
        XCTAssertFalse(screen.isLoading)
    }

    func testEachRemoveAsksItsOwnQuestion() throws {
        let rows = model(RelaySlotsState(macs: [linkedMac, unknownMac, finishingMac])).rows
        let unlink = try XCTUnwrap(RelaySlotsModel.ask(for: rows[0]))
        XCTAssertEqual(unlink.title, "Unlink Work Mac?")
        XCTAssertEqual(unlink.confirm, "Unlink")
        XCTAssertNil(RelaySlotsModel.ask(for: rows[1]), "a Mac not on this iPhone only frees its slot")
        let cancel = try XCTUnwrap(RelaySlotsModel.ask(for: rows[2]))
        XCTAssertEqual(cancel.title, "Cancel the link to build-box? It frees its Relay slot.")
        XCTAssertEqual([cancel.confirm, cancel.keep], ["Cancel Link", "Keep Trying"])
    }

    /// Review round 1: a linked Mac being removed keeps its name and kind (its registry row goes before
    /// `remove_slot` answers), and its Try Again asks nothing again.
    func testAPinnedRowKeepsItsNameWhileRemovedAndAfterAFailure() throws {
        let pinned = RelaySlotsModel.Pinned(name: "Work Mac", sub: nil, kind: .linkedHere(hubID: "hub-work"))
        let removing = RelaySlotsModel(
            state: RelaySlotsState(macs: [linkedMac], removing: linkedMac, pinned: [linkedMac: pinned]), links: [], promoted: []
        )
        XCTAssertEqual(removing.rows.first?.name, "Work Mac")
        XCTAssertEqual(removing.rows.first?.action, .removing)
        let failed = RelaySlotsModel(
            state: RelaySlotsState(macs: [linkedMac], failed: linkedMac, pinned: [linkedMac: pinned]), links: [], promoted: []
        )
        let row = try XCTUnwrap(failed.rows.first)
        XCTAssertEqual(row.name, "Work Mac")
        XCTAssertEqual(row.kind, .linkedHere(hubID: "hub-work"))
        XCTAssertEqual(row.action.title, "Try Again")
        XCTAssertNil(RelaySlotsModel.ask(for: row), "the removal was confirmed already")
    }

    func testRemovingAndRemoveError() {
        let removing = model(RelaySlotsState(macs: [linkedMac, unknownMac, finishingMac], removing: linkedMac))
        XCTAssertEqual(removing.rows.map(\.action.title), ["Removing…", "Remove", "Remove"])
        XCTAssertEqual(removing.rows.map(\.isDisabled), [false, true, true])
        let failed = model(RelaySlotsState(macs: [linkedMac, unknownMac, finishingMac], failed: linkedMac))
        XCTAssertEqual(failed.title, "Couldn't remove the Mac. Try again.")
        XCTAssertEqual(failed.rows.map(\.action.title), ["Try Again", "Remove", "Remove"])
        XCTAssertEqual(failed.rows.map(\.isDisabled), [false, false, false])
    }
}
