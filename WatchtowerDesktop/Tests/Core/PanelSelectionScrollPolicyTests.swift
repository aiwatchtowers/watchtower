import XCTest
@testable import WatchtowerCore

/// Board #561: the sessions panel (and the chat history) follow the selection,
/// and only the selection.
final class PanelSelectionScrollPolicyTests: XCTestCase {
    func testSelectionOfListedRowScrollsAtOnce() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertEqual(policy.panelScrollTarget(selecting: 4, rows: [5, 4, 3]), 4)
        XCTAssertNil(policy.pending)
    }

    func testNewSessionSelectedBeforeInsertScrollsWhenRowAppears() {
        // `activate` names the new session before `loadSessions` lists it.
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertNil(policy.panelScrollTarget(selecting: 9, rows: [5, 4]))
        XCTAssertEqual(policy.pending, 9)
        XCTAssertEqual(policy.panelScrollTarget(rows: [9, 5, 4]), 9)
        XCTAssertNil(policy.pending)
    }

    func testRowsRefreshWithoutPendingNeverScrolls() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        _ = policy.panelScrollTarget(selecting: 5, rows: [5, 4])
        XCTAssertNil(policy.panelScrollTarget(rows: [5, 4]))
        XCTAssertNil(policy.panelScrollTarget(rows: [4, 5]))
        XCTAssertNil(policy.panelScrollTarget(rows: [6, 5, 4]))
    }

    func testSelectionClearedDropsPending() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertNil(policy.panelScrollTarget(selecting: 9, rows: [5]))
        XCTAssertNil(policy.panelScrollTarget(selecting: nil, rows: [5]))
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.panelScrollTarget(rows: [9, 5]))
    }

    func testNewerSelectionReplacesPending() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertNil(policy.panelScrollTarget(selecting: 9, rows: [5]))
        XCTAssertNil(policy.panelScrollTarget(selecting: 10, rows: [5]))
        XCTAssertEqual(policy.pending, 10)
        XCTAssertNil(policy.panelScrollTarget(rows: [9, 5]))
        XCTAssertEqual(policy.panelScrollTarget(rows: [10, 9, 5]), 10)
        XCTAssertNil(policy.pending)
    }

    func testPendingRowNeverAppearingStaysQuiet() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertNil(policy.panelScrollTarget(selecting: 9, rows: [5]))
        XCTAssertNil(policy.panelScrollTarget(rows: [5]))
        XCTAssertNil(policy.panelScrollTarget(rows: []))
        XCTAssertNil(policy.panelScrollTarget(rows: [6, 5]))
    }

    func testSameSelectionAgainDoesNotRescroll() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertEqual(policy.panelScrollTarget(selecting: 4, rows: [5, 4]), 4)
        XCTAssertNil(policy.panelScrollTarget(selecting: 4, rows: [5, 4]))
        XCTAssertNil(policy.panelScrollTarget(rows: [5, 4]))
    }

    func testReselectingAfterAnotherRowScrollsAgain() {
        var policy = PanelSelectionScrollPolicy<Int64>()
        XCTAssertEqual(policy.panelScrollTarget(selecting: 4, rows: [5, 4]), 4)
        XCTAssertEqual(policy.panelScrollTarget(selecting: 5, rows: [5, 4]), 5)
        XCTAssertEqual(policy.panelScrollTarget(selecting: 4, rows: [5, 4]), 4)
    }
}
