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
        l.show(.files)
        XCTAssertEqual(l.primary, .files)
        XCTAssertFalse(l.isSplit)
    }

    func testShowSplitReplacesSecondary() {
        var l = split()
        l.show(.files)
        XCTAssertEqual(l.primary, .board)
        XCTAssertEqual(l.secondary, .files)
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
        l.show(.files)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.board, .files])
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
        var l = WorkspaceLayout(primary: .session(7), secondary: .files, expanded: nil, dividerFraction: 0.5)
        l.forgetSession(7, fallback: .board)
        XCTAssertEqual(l.primary, .files)
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

    /// The Documents pane is gone (spec 2026-10-03 Part 8): a layout saved
    /// naming it decodes to `.default`, as a pane this build does not know
    /// always has (the Files precedent).
    func testASavedLayoutNamingTheDocumentsPaneDecodesToDefault() {
        let saved = { (pane: String) in
            Data(#"{"primary":{"session":{"_0":3}},"secondary":{"\#(pane)":{}},"dividerFraction":0.4}"#.utf8)
        }
        XCTAssertEqual(WorkspaceLayout.decode(saved("files")).visiblePanes, [.session(3), .files],
                       "the same layout with a known pane still reads")
        XCTAssertEqual(WorkspaceLayout.decode(saved("documents")), .default)
        let expanded = #"{"primary":{"board":{}},"secondary":{"files":{}},"expanded":{"documents":{}},"dividerFraction":0.5}"#
        XCTAssertEqual(WorkspaceLayout.decode(Data(expanded.utf8)), .default)
    }

    func testTheHeaderViewsAreTerminalBoardAndFiles() {
        XCTAssertEqual(WorkspaceView.allCases, [.terminal, .board, .files])
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
        let stored = WorkspaceLayout(primary: .board, secondary: .session(1), expanded: .files, dividerFraction: 0.5)
        let decoded = WorkspaceLayout.decode(try JSONEncoder().encode(stored))
        XCTAssertNil(decoded.expanded)
        XCTAssertEqual(decoded.visiblePanes, [.board, .session(1)])
    }

    func testKey() {
        XCTAssertEqual(WorkspaceLayout.key(workbenchID: 12), "projects.layout.12")
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
        l.replace(.session(1), with: .files)
        XCTAssertEqual(l.secondary, .files)
        XCTAssertEqual(l.expanded, .files)
    }

    func testReplaceOfAPaneNotInASlotIsNoOp() {
        var l = split()
        let before = l
        XCTAssertFalse(l.replace(.files, with: .session(9)))
        XCTAssertEqual(l, before)
        XCTAssertTrue(l.replace(.board, with: .board), "a slot replaced by itself is applied, unchanged")
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
        l.split(with: .files)
        l.reveal(.session(3), keeping: .files)
        XCTAssertEqual(l.visiblePanes, [.session(3), .files])
        var m = WorkspaceLayout(primary: .files, secondary: .board, expanded: nil, dividerFraction: 0.5)
        m.reveal(.session(3), keeping: .files)
        XCTAssertEqual(m.visiblePanes, [.files, .session(3)])
    }

    func testRevealWhileTheKeptPaneIsExpandedShowsBoth() {
        var l = WorkspaceLayout(primary: .session(3), secondary: .files, expanded: .files, dividerFraction: 0.5)
        l.reveal(.session(3), keeping: .files)
        XCTAssertNil(l.expanded)
        XCTAssertEqual(l.visiblePanes, [.session(3), .files])
    }

    func testRevealInSinglePaneSwitchesToIt() {
        var l = WorkspaceLayout(primary: .files, secondary: nil, expanded: nil, dividerFraction: 0.5)
        l.reveal(.session(3), keeping: .files)
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

    // MARK: - Header view buttons

    func testIsShowingFollowsTheVisiblePanes() {
        var l = split()
        XCTAssertTrue(l.isShowing(.board))
        XCTAssertTrue(l.isShowing(.terminal))
        XCTAssertFalse(l.isShowing(.files))
        l.toggleExpand(.session(1))
        XCTAssertFalse(l.isShowing(.board), "an expansion hides the other pane")
    }

    func testShowProjectViewNeverHidesTheTerminal() {
        var l = WorkspaceLayout(primary: .session(1), secondary: .board, expanded: nil, dividerFraction: 0.5)
        l.showWorkbenchView(.files)
        XCTAssertEqual(l.visiblePanes, [.session(1), .files])

        l.toggleExpand(.files)
        l.showWorkbenchView(.board)
        XCTAssertEqual(l.visiblePanes, [.session(1), .board], "the expansion ends; the session stays")

        var single = WorkspaceLayout(primary: .session(1), secondary: nil, expanded: nil, dividerFraction: 0.5)
        single.showWorkbenchView(.board)
        XCTAssertEqual(single.visiblePanes, [.board], "a single pane switches")
    }

    func testShowProjectViewInASplitWithoutASession() {
        var l = WorkspaceLayout(primary: .board, secondary: .files, expanded: .files, dividerFraction: 0.5)
        l.showWorkbenchView(.board)
        XCTAssertEqual(l.visiblePanes, [.board, .files], "a pane in a slot comes back; the expansion ends")
    }

    func testHideClosesOnlyAPaneOfAVisibleSplit() {
        var l = split()
        l.hide(.board)
        XCTAssertEqual(l.visiblePanes, [.session(1)])
        XCTAssertFalse(l.isSplit)

        l.hide(.terminal)
        XCTAssertEqual(l.visiblePanes, [.session(1)], "the only pane stays")

        var expanded = split()
        expanded.toggleExpand(.board)
        expanded.hide(.board)
        XCTAssertEqual(expanded.visiblePanes, [.board], "an expanded pane stays")

        var other = split()
        other.hide(.files)
        XCTAssertEqual(other, split(), "a view not on screen changes nothing")
    }

    func testTerminalSlotIsTheVisibleSessionElseTheLastVisiblePane() {
        XCTAssertEqual(split().terminalSlot, .session(1))
        XCTAssertEqual(WorkspaceLayout.default.terminalSlot, .board, "a single pane is replaced")
        var views = WorkspaceLayout(primary: .board, secondary: .files, expanded: nil, dividerFraction: 0.5)
        XCTAssertEqual(views.terminalSlot, .files, "the first view stays, as with the Terminal button")
        views.toggleExpand(.board)
        XCTAssertEqual(views.terminalSlot, .board, "only what is on screen")
    }

    func testWorkspaceViewOfAPane() {
        XCTAssertEqual(WorkspaceView(.session(3)), .terminal)
        XCTAssertEqual(WorkspaceView(.board), .board)
        XCTAssertEqual(WorkspaceView(.files), .files)
        XCTAssertTrue(WorkspaceView.terminal.matches(.session(3)))
        XCTAssertFalse(WorkspaceView.board.matches(.files))
    }

    // POC (code viewer): the Files pane round-trips through the saved
    // layout, opens beside a terminal without displacing it, and is a
    // header view like the Board.
    func testFilesPaneRoundTripsAndKeepsTheTerminal() throws {
        var l = split()
        l.showWorkbenchView(.files)
        XCTAssertEqual(l.visiblePanes, [.files, .session(1)])
        XCTAssertEqual(WorkspaceView(.files), .files)
        XCTAssertTrue(l.isShowing(.files))
        XCTAssertEqual(WorkspaceLayout.decode(try JSONEncoder().encode(l)), l)
    }

    // MARK: - ⌘↵ in the go-to palette

    func testOpenBesideSplitsASinglePaneWithItSecond() {
        var l = WorkspaceLayout(primary: .session(1), secondary: nil, expanded: nil, dividerFraction: 0.5)
        l.openBeside(.session(2), keeping: .session(1))
        XCTAssertEqual(l.visiblePanes, [.session(1), .session(2)])
    }

    func testOpenBesideReplacesThePaneNotKept() {
        var l = WorkspaceLayout(primary: .board, secondary: .session(1), expanded: nil, dividerFraction: 0.5)
        l.openBeside(.session(2), keeping: .session(1))
        XCTAssertEqual(l.visiblePanes, [.session(2), .session(1)])

        l.openBeside(.session(3), keeping: .session(2))
        XCTAssertEqual(l.visiblePanes, [.session(2), .session(3)])
    }

    func testOpenBesideLeavesAPaneOnScreenAlone() {
        let l = WorkspaceLayout(primary: .board, secondary: .session(1), expanded: nil, dividerFraction: 0.5)
        var moved = l
        moved.openBeside(.session(1), keeping: .board)
        XCTAssertEqual(moved, l)

        var single = WorkspaceLayout(primary: .session(1), secondary: nil, expanded: nil, dividerFraction: 0.5)
        single.openBeside(.session(1), keeping: .session(1))
        XCTAssertFalse(single.isSplit)
    }

    func testOpenBesideOverAnExpansionShowsTheSplit() {
        var l = WorkspaceLayout(primary: .session(1), secondary: .board, expanded: .session(1), dividerFraction: 0.5)
        l.openBeside(.session(2), keeping: .session(1))
        XCTAssertEqual(l.visiblePanes, [.session(1), .session(2)])
    }
}
