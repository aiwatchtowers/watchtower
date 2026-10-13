import XCTest
@testable import WatchtowerCore

final class SessionPanelSectionsTests: XCTestCase {
    private let now = Date()
    private typealias State = SessionSwitcherPresentation.State

    private func session(_ id: Int64) -> TerminalSession {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        return TerminalSession(
            id: id, projectID: 1, kind: .claude, title: "Session \(id)", titleSource: .auto, targetID: nil,
            folderPath: "/tmp/acme", claudeSessionID: "uuid", createdAt: stamp, lastActiveAt: stamp
        )
    }

    private func status(_ id: Int64, _ state: State, finishedAt: String? = nil) -> SessionAgentStatus {
        SessionAgentStatus(sessionID: id, workbenchID: 1, workbenchName: "acme", title: "Session \(id)",
                           state: state, at: nil, finishedAt: finishedAt)
    }

    private func finished(_ id: Int64, at stamp: String = "2026-10-12T10:00:00.000Z") -> SessionAgentStatus {
        status(id, State(kind: .finished, live: false), finishedAt: stamp)
    }

    private func sections(
        _ ids: [Int64],
        saved: [Int64] = [],
        statuses: [SessionAgentStatus],
        live: Set<Int64> = [],
        expanded: Bool = false,
        sticky: SessionPanelSections.Sticky? = nil
    ) -> SessionPanelSections {
        SessionPanelSections.grouping(
            sessions: ids.map(session), savedOrder: saved,
            statuses: Dictionary(uniqueKeysWithValues: statuses.map { ($0.sessionID, $0) }),
            liveIDs: live, now: now, expanded: expanded, sticky: sticky
        )
    }

    func testFinishedWithoutAsksGoesToTheGroup() {
        let live = status(2, .live(.finished), finishedAt: "2026-10-12T10:00:00.000Z")
        let result = sections([1, 2, 3], saved: [1, 2, 3], statuses: [finished(1), live], live: [2], expanded: true)
        XCTAssertEqual(result.main.map(\.id), [3])
        XCTAssertEqual(result.finished.map(\.id), [2, 1], "live or not; a finish-time tie: newest id first")
        XCTAssertEqual(result.finishedCount, 2)
    }

    func testFinishedWithAnAskReadyAndStoppedStayInMain() {
        let withAsk = status(1, State(kind: .finished, live: false, openAsks: 1, oldestAskID: 5),
                             finishedAt: "2026-10-12T10:00:00.000Z")
        let waiting = status(2, State(kind: .waitingOnAsk, live: false, openAsks: 1, oldestAskID: 6))
        let stopped = status(3, .live(.stopped))
        let result = sections([1, 2, 3], saved: [1, 2, 3], statuses: [withAsk, waiting, stopped], live: [3],
                              expanded: true)
        XCTAssertEqual(result.main.map(\.id), [1, 2, 3])
        XCTAssertTrue(result.finished.isEmpty)
        XCTAssertEqual(result.finishedCount, 0)
        XCTAssertEqual(SessionPanelSections.panelSection(of: withAsk.state), .main)
    }

    func testGroupOrderedByFinishTimeNewestFirst() {
        let statuses = [
            finished(1, at: "2026-10-12T09:00:00.000Z"), finished(2, at: "2026-10-12T11:00:00.000Z"),
            finished(3, at: "2026-10-12T10:00:00.000Z"), finished(4, at: "2026-10-12T10:00:00.000Z")
        ]
        let result = sections([1, 2, 3, 4], saved: [1, 2, 3, 4], statuses: statuses, expanded: true)
        XCTAssertEqual(result.finished.map(\.id), [2, 4, 3, 1], "a tie falls back to the id, newest first")
    }

    func testFoldedGroupHasACountButNoRows() {
        let result = sections([1, 2, 3], saved: [1, 2, 3], statuses: [finished(1), finished(2)])
        XCTAssertFalse(result.expanded)
        XCTAssertTrue(result.finished.isEmpty)
        XCTAssertEqual(result.finishedCount, 2)
        XCTAssertNil(result.pinned)
        XCTAssertEqual(result.visibleOrder, [3])
    }

    func testStickyKeepsAJustFinishedOnScreenRowInMain() {
        let sticky = SessionPanelSections.Sticky(sessionID: 2, section: .main)
        let result = sections([1, 2, 3], saved: [1, 2, 3], statuses: [finished(2)], expanded: true, sticky: sticky)
        XCTAssertEqual(result.main.map(\.id), [1, 2, 3], "keeps its main-list slot")
        XCTAssertTrue(result.finished.isEmpty)
        XCTAssertEqual(result.finishedCount, 0)
        let unstuck = sections([1, 2, 3], saved: [1, 2, 3], statuses: [finished(2)], expanded: true)
        XCTAssertEqual(unstuck.main.map(\.id), [1, 3], "another session on screen: its real section")
    }

    func testStickyGroupRowIsPinnedUnderAFoldedHeader() {
        let sticky = SessionPanelSections.Sticky(sessionID: 1, section: .finished)
        let statuses = [finished(1), finished(2)]
        let folded = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses, sticky: sticky)
        XCTAssertEqual(folded.pinned?.id, 1)
        XCTAssertNil(folded.pinned?.shortcut, "a pinned row gets no number")
        XCTAssertTrue(folded.finished.isEmpty)
        XCTAssertEqual(folded.finishedCount, 2)
        XCTAssertEqual(folded.visibleOrder, [3, 1])
        let open = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses, expanded: true, sticky: sticky)
        XCTAssertNil(open.pinned, "an open group lists the row itself")
    }

    /// Owner brief #480 §1: a new prompt lifts `finished` and the session
    /// returns to its place in the main list, even while it is on screen
    /// with a sticky `.finished` section.
    func testSessionResumedFromTheGroupReturnsToMain() {
        let sticky = SessionPanelSections.Sticky(sessionID: 1, section: .finished)
        let statuses = [status(1, .live(.working)), finished(2)]
        for expanded in [false, true] {
            let result = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses, live: [1],
                                  expanded: expanded, sticky: sticky)
            XCTAssertEqual(result.main.map(\.id), [1, 3], "back in its saved slot (expanded: \(expanded))")
            XCTAssertNil(result.pinned, "not pinned under the header (expanded: \(expanded))")
            XCTAssertEqual(result.finished.map(\.id), expanded ? [2] : [])
            XCTAssertEqual(result.finishedCount, 1, "only the really finished row counts (expanded: \(expanded))")
        }
    }

    func testShortcutsNumberMainFirstGroupOnlyWhenOpen() {
        let statuses = [finished(1, at: "2026-10-12T09:00:00.000Z"), finished(2, at: "2026-10-12T10:00:00.000Z")]
        let folded = sections([1, 2, 3, 4], saved: [1, 2, 3, 4], statuses: statuses)
        XCTAssertEqual(folded.main.map(\.shortcut), [1, 2])
        XCTAssertEqual(folded.shortcutOrder, [3, 4])
        let open = sections([1, 2, 3, 4], saved: [1, 2, 3, 4], statuses: statuses, expanded: true)
        XCTAssertEqual(open.main.map(\.shortcut), [1, 2], "folding never renumbers the main list")
        XCTAssertEqual(open.finished.map(\.shortcut), [3, 4])
        XCTAssertEqual(open.shortcutOrder, [3, 4, 2, 1])
        XCTAssertEqual(open.visibleOrder, [3, 4, 2, 1])
    }

    func testNeighbourIsNextThenPreviousThenNil() {
        XCTAssertEqual(SessionPanelSections.panelNeighbour(of: 2, in: [1, 2, 3]), 3)
        XCTAssertEqual(SessionPanelSections.panelNeighbour(of: 3, in: [1, 2, 3]), 2)
        XCTAssertNil(SessionPanelSections.panelNeighbour(of: 1, in: [1]))
        XCTAssertNil(SessionPanelSections.panelNeighbour(of: 9, in: [1, 2]), "not listed")
    }

    func testMainKeepsTheSavedDragOrder() {
        let result = sections([1, 2, 3, 4, 5], saved: [3, 5, 1, 4], statuses: [finished(5)], expanded: true)
        XCTAssertEqual(result.main.map(\.id), [2, 3, 1, 4], "never placed on top, then the saved order")
        XCTAssertEqual(result.finished.map(\.id), [5])
    }

    /// The switcher and ⌘K list every group row even while the panel's
    /// group is folded; their shortcuts still follow the fold.
    func testSearchRowsListEveryGroupRowEvenFolded() {
        let statuses = [finished(1, at: "2026-10-12T09:00:00.000Z"), finished(2, at: "2026-10-12T10:00:00.000Z")]
        let folded = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses)
        XCTAssertEqual(folded.searchRows.map(\.id), [3, 2, 1], "main, then the group newest first")
        XCTAssertEqual(folded.searchRows.map(\.shortcut), [1, nil, nil], "a folded group's rows get no number")
        let open = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses, expanded: true)
        XCTAssertEqual(open.searchRows.map(\.shortcut), [1, 2, 3])
    }

    /// #561's scroll covers the group: the header has its own scroll id,
    /// listed between the main rows and the group's.
    func testScrollIDsListTheHeaderBetweenMainAndGroup() {
        let header = SessionPanelSections.groupHeaderScrollID
        let statuses = [finished(1), finished(2)]
        let open = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses, expanded: true)
        XCTAssertEqual(open.panelScrollIDs, [3, header, 2, 1])
        let pinned = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses,
                              sticky: .init(sessionID: 1, section: .finished))
        XCTAssertEqual(pinned.panelScrollIDs, [3, header, 1])
        let none = sections([1, 2], saved: [1, 2], statuses: [])
        XCTAssertEqual(none.panelScrollIDs, [1, 2], "no group, no header")
    }

    /// A row under the header (open group or pinned) scrolls the header in
    /// first; a main row, alone; nothing for no target.
    func testScrollPathBringsTheHeaderInForAGroupRow() {
        let header = SessionPanelSections.groupHeaderScrollID
        let statuses = [finished(1), finished(2)]
        let pinned = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses,
                              sticky: .init(sessionID: 1, section: .finished))
        XCTAssertEqual(pinned.panelScrollPath(to: 1), [header, 1])
        XCTAssertEqual(pinned.panelScrollPath(to: 3), [3])
        XCTAssertEqual(pinned.panelScrollPath(to: nil), [])
        let open = sections([1, 2, 3], saved: [1, 2, 3], statuses: statuses, expanded: true)
        XCTAssertEqual(open.panelScrollPath(to: 2), [header, 2])
    }

    /// A finished session launched before the states are read again keeps
    /// its stored section: a launch alone is not a resume (#480).
    func testLaunchBeforeTheStatesAreReadMovesNoRow() {
        let result = sections([1, 2], saved: [1, 2], statuses: [finished(1)], live: [1], expanded: true)
        XCTAssertEqual(result.main.map(\.id), [2])
        XCTAssertEqual(result.finished.map(\.id), [1])
        let statuses = [Int64(1): finished(1)]
        XCTAssertEqual(SessionPanelSections.panelSection(of: 1, liveIDs: [1], statuses: statuses), .finished)
        XCTAssertEqual(SessionPanelSections.panelSection(of: 2, liveIDs: [2], statuses: statuses), .main,
                       "no state read yet: a running row")
    }
}
