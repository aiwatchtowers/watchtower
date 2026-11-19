import DesignKit
import SwiftUI
import ViewInspector
import WatchtowerInterface
import XCTest

/// The shared row treatment of a press through the tower (mockup §8).
@MainActor
final class TowerRowStateTests: XCTestCase {
    func testBusyShowsItsLabel() throws {
        let view = TowerRowState(state: .busy, busyLabel: "Approving…") {}
        XCTAssertNoThrow(try view.inspect().find(text: "Approving…"))
        XCTAssertThrowsError(try view.inspect().find(button: TowerText.retry))
    }

    func testRefusedShowsTheSentenceAndRetry() throws {
        var retried = 0
        let view = TowerRowState(state: .refused("Couldn't approve it: this idea changed — look again."),
                                 busyLabel: "Approving…") { retried += 1 }
        XCTAssertNoThrow(try view.inspect().find(text: "Couldn't approve it: this idea changed — look again."))
        try view.inspect().find(button: TowerText.retry).tap()
        XCTAssertEqual(retried, 1)
    }

    func testUnknownSaysItDidNotConfirm() throws {
        let view = TowerRowState(state: .unknown, busyLabel: "Approving…") {}
        XCTAssertNoThrow(try view.inspect().find(text: TowerText.didntConfirmMac))
        XCTAssertEqual(TowerText.didntConfirmMac, "Didn't confirm — checking again…")
        XCTAssertThrowsError(try view.inspect().find(button: TowerText.retry), "never re-sent")
    }

    func testNoStateDrawsNothing() throws {
        let view = TowerRowState(state: nil, busyLabel: "Approving…") {}
        XCTAssertThrowsError(try view.inspect().find(text: "Approving…"))
    }
}
