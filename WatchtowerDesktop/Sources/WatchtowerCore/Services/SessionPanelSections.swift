import Foundation

/// The workbench sessions panel split into the main list and the "▸ N
/// finished" group (board #480, spec 2026-10-12-sessions-panel-design §3):
/// a session that finished with no open ask folds into the group, live or
/// not; every other row stays in the main list in the saved drag order.
/// Pure, so the panel, the switcher, ⌘1…⌘9 and ⌘K read one split.
package struct SessionPanelSections: Equatable, Sendable {
    package enum Section: Equatable, Sendable { case main, finished }

    /// The on-screen session's section, kept while it stays on screen so a
    /// row never jumps under the owner's eyes (§3.3).
    package struct Sticky: Equatable, Sendable {
        package let sessionID: Int64
        package let section: Section

        package init(sessionID: Int64, section: Section) {
            self.sessionID = sessionID
            self.section = section
        }
    }

    /// The main list, in the saved drag order.
    package let main: [SessionSwitcherPresentation.Row]
    /// The group's rows, most recently finished first; empty while folded.
    package let finished: [SessionSwitcherPresentation.Row]
    /// The group's size, folded or not — the header's "N finished".
    package let finishedCount: Int
    /// Folded, with the on-screen session in the group: that one row shows
    /// under the header without changing the remembered fold.
    package let pinned: SessionSwitcherPresentation.Row?
    /// Whether the group is open (the remembered fold).
    package let expanded: Bool
    /// Every group row, folded or not (numbered only while open): the
    /// session switcher and ⌘K list them all — they are search surfaces.
    package let groupRows: [SessionSwitcherPresentation.Row]

    /// The group header's scroll id in the panel's list (a session id is a
    /// rowid, never negative), so the selection scroll (#561) can bring the
    /// header into view with the group row under it.
    package static let groupHeaderScrollID: Int64 = -1

    /// The switcher's and ⌘K's order: the main list, then every group row.
    package var searchRows: [SessionSwitcherPresentation.Row] {
        main + groupRows
    }

    /// ⌘1…⌘9 follow this: the main ids, then the group's only while open
    /// (the pinned row gets no number).
    package var shortcutOrder: [Int64] {
        main.map(\.id) + finished.map(\.id)
    }

    /// Every session row the panel shows, top to bottom: main, then the open
    /// group or the pinned row — the ↑ ↓ cursor's order and the ids the
    /// panel's selection scroll (`PanelSelectionScrollPolicy`, #561) finds
    /// listed. The group header is not a session row; the panel lists it
    /// under `finishedCount > 0`.
    package var visibleOrder: [Int64] {
        main.map(\.id) + finished.map(\.id) + (pinned.map { [$0.id] } ?? [])
    }

    /// The panel list's scroll ids top to bottom: the main rows, the group
    /// header (while the group has rows), then the open group or the pinned
    /// row.
    package var panelScrollIDs: [Int64] {
        let header = finishedCount > 0 ? [Self.groupHeaderScrollID] : []
        return main.map(\.id) + header + finished.map(\.id) + (pinned.map { [$0.id] } ?? [])
    }

    /// What the panel scrolls to, in turn, to show `id` (a
    /// `PanelSelectionScrollPolicy` target): a row under the group header
    /// (open group or pinned) brings the header in first, so the row is
    /// never shown cut off from its group; any other id alone.
    package func panelScrollPath(to id: Int64?) -> [Int64] {
        guard let id else { return [] }
        let underHeader = finished.contains { $0.id == id } || pinned?.id == id
        return underHeader ? [Self.groupHeaderScrollID, id] : [id]
    }

    /// The split of a workbench's `sessions` (pending deletes already
    /// dropped). `savedOrder` is the panel's saved drag order; `sticky` the
    /// on-screen session's kept section, if any; `places` labels the agent
    /// rows (`Row.place`, #565). Only rows that are really
    /// finished fold, so `finishedCount` counts finished sessions only.
    package static func grouping(
        sessions: [TerminalSession],
        savedOrder: [Int64],
        statuses: [Int64: SessionAgentStatus],
        liveIDs: Set<Int64>,
        now: Date,
        expanded: Bool,
        sticky: Sticky?,
        places: [Int64: SessionPlacePresentation.PlaceLabel] = [:]
    ) -> Self {
        let ordered = TerminalSessionOrder.apply(sessions, saved: savedOrder)
        var mainSessions: [TerminalSession] = []
        var groupSessions: [TerminalSession] = []
        for session in ordered {
            let state = SessionSwitcherPresentation.state(of: session.id, liveIDs: liveIDs, statuses: statuses)
            if heldInGroup(session.id, state: state, sticky: sticky) { groupSessions.append(session) } else { mainSessions.append(session) }
        }
        groupSessions.sort { finishedFirst($0, $1, statuses: statuses) }
        let numbered = mainSessions.map(\.id) + (expanded ? groupSessions.map(\.id) : [])
        let rows = SessionSwitcherPresentation.rows(
            mainSessions + groupSessions, liveIDs: liveIDs, statuses: statuses, now: now, shortcutOrder: numbered,
            places: places
        )
        let mainRows = Array(rows.prefix(mainSessions.count))
        let groupRows = Array(rows.dropFirst(mainSessions.count))
        let pinned = expanded ? nil : groupRows.first { $0.id == sticky?.sessionID }
        return Self(
            main: mainRows, finished: expanded ? groupRows : [], finishedCount: groupRows.count,
            pinned: pinned, expanded: expanded, groupRows: groupRows
        )
    }

    /// Whether a row folds into the group. Its real section decides, except
    /// that the on-screen session which finished in front of the owner keeps
    /// its main-list slot (sticky `.main`). A session resumed from the group
    /// (a new prompt, no longer finished) always returns to the main list:
    /// the sticky section never holds a row that is not finished (owner
    /// brief #480 §1).
    private static func heldInGroup(
        _ id: Int64, state: SessionSwitcherPresentation.State, sticky: Sticky?
    ) -> Bool {
        guard panelSection(of: state) == .finished else { return false }
        return !(sticky?.sessionID == id && sticky?.section == .main)
    }

    /// A row's real section: finished with no open ask → the group;
    /// everything else (a finished session with an open ask included) waits
    /// for the owner in the main list.
    package static func panelSection(of state: SessionSwitcherPresentation.State) -> Section {
        state.kind == .finished && state.openAsks == 0 ? .finished : .main
    }

    /// Where the panel cursor goes after `id` leaves `visible`: the next
    /// row, else the previous one, else nil (also nil when `id` is not
    /// listed).
    package static func panelNeighbour(of id: Int64, in visible: [Int64]) -> Int64? {
        guard let index = visible.firstIndex(of: id) else { return nil }
        if index + 1 < visible.count { return visible[index + 1] }
        return index > 0 ? visible[index - 1] : nil
    }

    /// The group's order: `finished_at` newest first (Go writes one UTC
    /// format, so the strings sort as times), then the id newest first.
    private static func finishedFirst(
        _ lhs: TerminalSession, _ rhs: TerminalSession, statuses: [Int64: SessionAgentStatus]
    ) -> Bool {
        let left = statuses[lhs.id]?.finishedAt ?? ""
        let right = statuses[rhs.id]?.finishedAt ?? ""
        return left != right ? left > right : lhs.id > rhs.id
    }
}
