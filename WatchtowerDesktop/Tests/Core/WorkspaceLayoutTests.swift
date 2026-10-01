import XCTest
@testable import WatchtowerCore

final class WorkspaceLayoutTests: XCTestCase {
    private func split() -> WorkspaceLayout {
        var l = WorkspaceLayout.default
        l.split(with: .session(1))
        return l
    }

    func testExpandAndRestore() {
        var l = split()
        l.toggleExpand(.board)
        XCTAssertEqual(l.visiblePanes, [.board])
        l.toggleExpand(.board)
        XCTAssertEqual(l.visiblePanes, [.board, .session(1)])
    }

    func testSplitWithPrimaryIsNoOp() {
        var l = WorkspaceLayout.default
        l.split(with: .board)
        XCTAssertEqual(l, .default)
    }

    func testUnsplitKeepsPrimary() {
        var l = split()
        l.toggleExpand(.session(1))
        l.unsplit()
        XCTAssertEqual(l.primary, .board)
        XCTAssertNil(l.secondary)
        XCTAssertNil(l.expanded)
    }

    func testShowSingleReplacesPrimary() {
        var l = WorkspaceLayout.default
        l.show(.documents)
        XCTAssertEqual(l.primary, .documents)
        XCTAssertFalse(l.isSplit)
    }

    func testShowSplitReplacesSecondary() {
        var l = split()
        l.show(.documents)
        XCTAssertEqual(l.primary, .board)
        XCTAssertEqual(l.secondary, .documents)
    }

    func testShowVisibleIsNoOp() {
        var l = split()
        let before = l
        l.show(.session(1))
        l.show(.board)
        XCTAssertEqual(l, before)
    }

    func testShowWhileExpandedClearsExpansion() {
        var l = split()
        l.toggleExpand(.board)
        l.show(.documents)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.board, .documents])
    }

    func testShowSlottedPaneWhileExpandedRestoresSplit() {
        var l = split()
        l.toggleExpand(.session(1))
        l.show(.board)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.board, .session(1)])
    }

    func testToggleExpandSinglePaneIsNoOp() {
        var l = WorkspaceLayout.default
        l.toggleExpand(.board)
        XCTAssertEqual(l, .default)
    }

    func testForgetSecondaryBecomesSingle() {
        var l = split()
        l.forgetSession(1, fallback: .board)
        XCTAssertEqual(l, .default)
    }

    func testForgetPrimaryPromotesSecondaryOrFallsBack() {
        var l = WorkspaceLayout(primary: .session(7), secondary: .documents, expanded: nil, dividerFraction: 0.5)
        l.forgetSession(7, fallback: .board)
        XCTAssertEqual(l.primary, .documents)
        XCTAssertNil(l.secondary)

        var single = WorkspaceLayout(primary: .session(7), secondary: nil, expanded: nil, dividerFraction: 0.5)
        single.forgetSession(7, fallback: .board)
        XCTAssertEqual(single.primary, .board)
    }

    func testForgetExpandedClearsExpansion() {
        var l = split()
        l.toggleExpand(.session(1))
        l.forgetSession(1, fallback: .board)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.board])
    }

    func testForgetOtherSessionChangesNothing() {
        var l = split()
        l.forgetSession(99, fallback: .board)
        XCTAssertEqual(l, split())
    }

    func testJSONRoundTrip() throws {
        var l = split()
        l.toggleExpand(.session(1))
        l.dividerFraction = 0.3
        let data = try JSONEncoder().encode(l)
        XCTAssertEqual(WorkspaceLayout.decode(data), l)
    }

    func testDecodeJunkAndMissingGiveDefault() {
        XCTAssertEqual(WorkspaceLayout.decode(Data("junk".utf8)), .default)
        XCTAssertEqual(WorkspaceLayout.decode(nil), .default)
    }

    func testDecodeClampsFraction() throws {
        var l = WorkspaceLayout.default
        l.dividerFraction = 1.5
        XCTAssertEqual(WorkspaceLayout.decode(try JSONEncoder().encode(l)).dividerFraction, 0.8)
        l.dividerFraction = -1
        XCTAssertEqual(WorkspaceLayout.decode(try JSONEncoder().encode(l)).dividerFraction, 0.2)
    }

    func testDecodeDropsSecondaryEqualToPrimary() throws {
        let stored = WorkspaceLayout(primary: .board, secondary: .board, expanded: .board, dividerFraction: 0.5)
        XCTAssertEqual(WorkspaceLayout.decode(try JSONEncoder().encode(stored)), .default)
    }

    func testDecodeDropsExpansionOutsideSlots() throws {
        let stored = WorkspaceLayout(primary: .board, secondary: .session(1), expanded: .documents, dividerFraction: 0.5)
        let decoded = WorkspaceLayout.decode(try JSONEncoder().encode(stored))
        XCTAssertNil(decoded.expanded)
        XCTAssertEqual(decoded.visiblePanes, [.board, .session(1)])
    }

    func testKey() {
        XCTAssertEqual(WorkspaceLayout.key(projectID: 12), "projects.layout.12")
    }

    // MARK: - Pane pickers, close, Send comments, divider

    func testReplaceSwapsWhenThePaneIsInTheOtherSlot() {
        var l = split()
        l.replace(.board, with: .session(1))
        XCTAssertEqual(l.primary, .session(1))
        XCTAssertEqual(l.secondary, .board)
    }

    func testReplaceFillsTheSlotAndKeepsTheExpansionOnIt() {
        var l = split()
        l.toggleExpand(.session(1))
        l.replace(.session(1), with: .documents)
        XCTAssertEqual(l.secondary, .documents)
        XCTAssertEqual(l.expanded, .documents)
    }

    func testReplaceOfAPaneNotInASlotIsNoOp() {
        var l = split()
        let before = l
        l.replace(.documents, with: .session(9))
        XCTAssertEqual(l, before)
    }

    func testRemoveInSplitKeepsTheOtherPane() {
        var l = split()
        l.remove(.board)
        XCTAssertEqual(l.primary, .session(1))
        XCTAssertFalse(l.isSplit)
        var m = split()
        m.toggleExpand(.board)
        m.remove(.session(1))
        XCTAssertEqual(m.visiblePanes, [.board])
        XCTAssertNil(m.expanded)
    }

    func testRemoveTheOnlyPaneIsNoOp() {
        var l = WorkspaceLayout.default
        l.remove(.board)
        XCTAssertEqual(l, .default)
    }

    func testRevealVisiblePaneChangesNothing() {
        var l = split()
        let before = l
        l.reveal(.session(1), keeping: .board)
        XCTAssertEqual(l, before)
    }

    func testRevealInSplitReplacesThePaneThatIsNotKept() {
        var l = WorkspaceLayout.default
        l.split(with: .documents)
        l.reveal(.session(3), keeping: .documents)
        XCTAssertEqual(l.visiblePanes, [.session(3), .documents])
        var m = WorkspaceLayout(primary: .documents, secondary: .board, expanded: nil, dividerFraction: 0.5)
        m.reveal(.session(3), keeping: .documents)
        XCTAssertEqual(m.visiblePanes, [.documents, .session(3)])
    }

    func testRevealWhileTheKeptPaneIsExpandedShowsBoth() {
        var l = WorkspaceLayout(primary: .session(3), secondary: .documents, expanded: .documents, dividerFraction: 0.5)
        l.reveal(.session(3), keeping: .documents)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.session(3), .documents])
    }

    func testRevealInSinglePaneSwitchesToIt() {
        var l = WorkspaceLayout(primary: .documents, secondary: nil, expanded: nil, dividerFraction: 0.5)
        l.reveal(.session(3), keeping: .documents)
        XCTAssertEqual(l.visiblePanes, [.session(3)])
    }

    func testDividerFractionIsClamped() {
        var l = split()
        l.setDividerFraction(0.05)
        XCTAssertEqual(l.dividerFraction, 0.2)
        l.setDividerFraction(0.65)
        XCTAssertEqual(l.dividerFraction, 0.65)
    }

    func testSessionIDs() {
        let l = WorkspaceLayout(primary: .session(4), secondary: .session(2), expanded: nil, dividerFraction: 0.5)
        XCTAssertEqual(l.sessionIDs, [4, 2])
        XCTAssertEqual(WorkspaceLayout.default.sessionIDs, [])
    }
}
