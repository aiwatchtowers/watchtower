import XCTest
@testable import WatchtowerCore

/// The ⌘K palette's keyboard model (board #252): ↑↓ without wrapping,
/// ↵ opens, ⌘↵ splits only a current-workbench session, esc closes.
final class GoToPaletteSelectionTests: XCTestCase {
    private let current = Workbench(row: ["id": 1, "name": "alpha", "folder_path": "/tmp/1"])
    private let other = Workbench(row: ["id": 2, "name": "beta", "folder_path": "/tmp/2"])

    private func session(_ id: Int64, _ workbench: Workbench) -> TerminalSession {
        TerminalSession(
            id: id, projectID: workbench.id, kind: .claude, title: "s\(id)", titleSource: .auto, targetID: nil,
            folderPath: workbench.folderPath, claudeSessionID: "uuid",
            createdAt: "2026-09-01T10:00:00Z", lastActiveAt: "2026-09-01T10:00:00Z"
        )
    }

    private var otherRow: WorkbenchSwitcherSummary {
        WorkbenchSwitcherSummary(
            summary: WorkbenchSummary(project: other, openTargets: 0, inProgressTargets: 0,
                                      unreadAgentComments: 0, documentStamps: [:]),
            blockedTargets: 0, sessionCount: 1, lastSessionActivity: ""
        )
    }

    /// alpha's s1, s2; then beta's row and its s3.
    private var items: [GoToItem] {
        [.session(session(1, current), workbench: current), .session(session(2, current), workbench: current),
         .workbench(otherRow), .session(session(3, other), workbench: other)]
    }

    private func press(_ keys: GoToPaletteSelection.Key..., on selection: inout GoToPaletteSelection)
        -> GoToPaletteSelection.Outcome {
        var last = GoToPaletteSelection.Outcome.ignored
        for key in keys {
            last = selection.handle(key, items: items, currentWorkbenchID: current.id)
        }
        return last
    }

    func testTheFirstRowIsSelectedAtFirst() {
        XCTAssertEqual(GoToPaletteSelection().selected(in: items)?.id, "session-1")
        XCTAssertNil(GoToPaletteSelection().selected(in: []))
    }

    func testArrowsMoveWithoutWrapping() {
        var selection = GoToPaletteSelection()
        XCTAssertEqual(press(.up, on: &selection), .ignored)
        XCTAssertEqual(selection.selected(in: items)?.id, "session-1", "↑ on the first row stays")

        _ = press(.down, .down, on: &selection)
        XCTAssertEqual(selection.selected(in: items)?.id, "workbench-2")
        _ = press(.down, .down, .down, on: &selection)
        XCTAssertEqual(selection.selected(in: items)?.id, "session-3", "↓ on the last row stays")
        _ = press(.up, on: &selection)
        XCTAssertEqual(selection.selected(in: items)?.id, "workbench-2")
    }

    func testReturnOpensTheSelectedRow() {
        var selection = GoToPaletteSelection()
        XCTAssertEqual(press(.open, on: &selection), .open(items[0]))
        XCTAssertEqual(press(.down, .down, .open, on: &selection), .open(items[2]), "a workbench row")
    }

    func testCommandReturnSplitsOnlyACurrentWorkbenchSession() {
        var selection = GoToPaletteSelection()
        XCTAssertEqual(press(.down, .openInSplit, on: &selection), .openInSplit(session(2, current)))
        XCTAssertEqual(press(.down, .openInSplit, on: &selection), .open(items[2]),
                       "another workbench's row: like ↵")
        XCTAssertEqual(press(.down, .openInSplit, on: &selection), .open(items[3]),
                       "another workbench's session: like ↵")

        var noCurrent = GoToPaletteSelection()
        XCTAssertEqual(noCurrent.handle(.openInSplit, items: items, currentWorkbenchID: nil), .open(items[0]),
                       "no workbench page: nothing to split")
    }

    func testEscapeCloses() {
        var selection = GoToPaletteSelection()
        XCTAssertEqual(press(.close, on: &selection), .close)
    }

    func testNothingListedOpensNothing() {
        var selection = GoToPaletteSelection()
        for key in [GoToPaletteSelection.Key.up, .down, .open, .openInSplit] {
            XCTAssertEqual(selection.handle(key, items: [], currentWorkbenchID: current.id), .ignored)
        }
        XCTAssertEqual(selection.handle(.close, items: [], currentWorkbenchID: current.id), .close)
    }

    /// New results (a reload) keep the selected row while it is listed;
    /// once it is gone the first row is selected; `reset` (a query edit)
    /// goes back to the first row.
    func testTheSelectionFollowsItsRowAcrossNewResults() {
        var selection = GoToPaletteSelection()
        _ = press(.down, .down, on: &selection)
        XCTAssertEqual(selection.selected(in: Array(items.reversed()))?.id, "workbench-2")
        XCTAssertEqual(selection.selected(in: [items[3]])?.id, "session-3")
        XCTAssertEqual(selection.handle(.down, items: [items[0], items[1]], currentWorkbenchID: current.id), .ignored)
        XCTAssertEqual(selection.selected(in: items)?.id, "session-2", "moved from the first row when its row was gone")

        selection.select("session-3")
        XCTAssertEqual(selection.selected(in: items)?.id, "session-3")
        selection.reset()
        XCTAssertEqual(selection.selected(in: items)?.id, "session-1")
    }
}
