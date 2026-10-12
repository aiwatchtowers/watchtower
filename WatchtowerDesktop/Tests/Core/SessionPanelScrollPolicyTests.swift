import XCTest
@testable import WatchtowerCore

/// Board #561: the sessions panel (and the chat history) follow the selection,
/// and only the selection.
final class SessionPanelScrollPolicyTests: XCTestCase {
    func testSelectionOfListedRowScrollsAtOnce() {
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertEqual(policy.selectionChanged(to: 4, rows: [5, 4, 3]), 4)
        XCTAssertNil(policy.pending)
    }

    func testNewSessionSelectedBeforeInsertScrollsWhenRowAppears() {
        // `activate` names the new session before `loadSessions` lists it.
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertNil(policy.selectionChanged(to: 9, rows: [5, 4]))
        XCTAssertEqual(policy.pending, 9)
        XCTAssertEqual(policy.rowsChanged([9, 5, 4]), 9)
        XCTAssertNil(policy.pending)
    }

    func testRowsRefreshWithoutPendingNeverScrolls() {
        var policy = SessionPanelScrollPolicy<Int64>()
        _ = policy.selectionChanged(to: 5, rows: [5, 4])
        XCTAssertNil(policy.rowsChanged([5, 4]))
        XCTAssertNil(policy.rowsChanged([4, 5]))
        XCTAssertNil(policy.rowsChanged([6, 5, 4]))
    }

    func testSelectionClearedDropsPending() {
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertNil(policy.selectionChanged(to: 9, rows: [5]))
        XCTAssertNil(policy.selectionChanged(to: nil, rows: [5]))
        XCTAssertNil(policy.pending)
        XCTAssertNil(policy.rowsChanged([9, 5]))
    }

    func testNewerSelectionReplacesPending() {
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertNil(policy.selectionChanged(to: 9, rows: [5]))
        XCTAssertNil(policy.selectionChanged(to: 10, rows: [5]))
        XCTAssertEqual(policy.pending, 10)
        XCTAssertNil(policy.rowsChanged([9, 5]))
        XCTAssertEqual(policy.rowsChanged([10, 9, 5]), 10)
        XCTAssertNil(policy.pending)
    }

    func testPendingRowNeverAppearingStaysQuiet() {
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertNil(policy.selectionChanged(to: 9, rows: [5]))
        XCTAssertNil(policy.rowsChanged([5]))
        XCTAssertNil(policy.rowsChanged([]))
        XCTAssertNil(policy.rowsChanged([6, 5]))
    }

    func testSameSelectionAgainDoesNotRescroll() {
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertEqual(policy.selectionChanged(to: 4, rows: [5, 4]), 4)
        XCTAssertNil(policy.selectionChanged(to: 4, rows: [5, 4]))
        XCTAssertNil(policy.rowsChanged([5, 4]))
    }

    func testReselectingAfterAnotherRowScrollsAgain() {
        var policy = SessionPanelScrollPolicy<Int64>()
        XCTAssertEqual(policy.selectionChanged(to: 4, rows: [5, 4]), 4)
        XCTAssertEqual(policy.selectionChanged(to: 5, rows: [5, 4]), 5)
        XCTAssertEqual(policy.selectionChanged(to: 4, rows: [5, 4]), 4)
    }
}
