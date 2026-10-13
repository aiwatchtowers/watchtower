import XCTest
@testable import WatchtowerMobile

/// Settings → Macs' decisions (multi-hub spec §5.6): one destructive action
/// per row, its confirmation copy, and the move's registry index.
@MainActor
final class MacsModelTests: XCTestCase {
    private func item(removed: Bool = false, canForget: Bool = false) -> HubListItem {
        HubListItem(
            id: "hub-acme", name: "Acme Mac", flavor: nil, online: false, offlineDays: nil, openAsks: 0,
            isActive: false, removedByMac: removed, canForget: canForget, problem: nil
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

    func testMoveIndexMath() {
        XCTAssertEqual(MacsModel.targetIndex(from: 2, destination: 0), 0, "up")
        XCTAssertEqual(MacsModel.targetIndex(from: 0, destination: 3), 2, "down: the offset counts the row itself")
        XCTAssertNil(MacsModel.targetIndex(from: 1, destination: 1), "dropped where it was")
        XCTAssertNil(MacsModel.targetIndex(from: 1, destination: 2), "just below itself")
    }
}
