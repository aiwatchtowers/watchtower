import Foundation
import WatchtowerCore

/// The sessions panel's main list and its "▸ N finished" group (board #480,
/// spec 2026-10-12-sessions-panel-design §3): the split, the remembered
/// fold, the on-screen session's kept section, and the one order the panel,
/// ⌘1…⌘9, the session switcher and ⌘K share.
extension WorkbenchesViewModel {
    /// UserDefaults key of a workbench's fold (Bool, default folded).
    static func finishedGroupKey(workbenchID: Int64) -> String {
        "projects.finishedSessionsExpanded.\(workbenchID)"
    }

    /// Whether the workbench's finished group is open; folded until the
    /// owner opens it.
    func isFinishedGroupExpanded(projectID: Int64) -> Bool {
        finishedGroupFolds[projectID] ?? defaults.bool(forKey: Self.finishedGroupKey(workbenchID: projectID))
    }

    /// The header's click: remembered per workbench. The cache is what
    /// re-renders the panel (UserDefaults is not observed).
    func setFinishedGroupExpanded(_ expanded: Bool, projectID: Int64) {
        finishedGroupFolds[projectID] = expanded
        defaults.set(expanded, forKey: Self.finishedGroupKey(workbenchID: projectID))
    }

    /// A workbench's sessions as the panel splits them (pending deletes are
    /// not listed): the main list in the saved drag order, the group by
    /// finish time, the on-screen session kept where it was.
    func panelSections(projectID: Int64) -> SessionPanelSections {
        let sessions = terminalSessions[projectID] ?? []
        return SessionPanelSections.grouping(
            sessions: sessions, savedOrder: sessionOrder(projectID: projectID), statuses: sessionStatuses,
            liveIDs: terminalCenter?.liveIDs ?? [], now: now(),
            expanded: isFinishedGroupExpanded(projectID: projectID),
            sticky: panelSticky(projectID: projectID), places: sessionPlaceLabels(sessions)
        )
    }

    /// The switcher's and ⌘K's order of a workbench: the panel's main list,
    /// then every finished session (folded or not).
    func panelOrderedSessions(projectID: Int64) -> [TerminalSession] {
        panelSections(projectID: projectID).searchRows.map(\.session)
    }

    /// A drag in a session list; the new order is saved for that list.
    /// `displayed` is the list the drag's offsets index — the one the view
    /// rendered, not a re-read that a reload may have changed meanwhile.
    /// The sessions panel shows only its main list (#480): every other
    /// session — the finished group, one waiting in the Undo batch — keeps
    /// its saved slot (`TerminalSessionOrder.move(_:within:…)`).
    func moveSessions(_ displayed: [TerminalSession], projectID: Int64?, from source: IndexSet, to destination: Int) {
        let order = TerminalSessionOrder.move(
            displayed, within: savedSlots(projectID: projectID), from: source, to: destination
        )
        sessionOrders[projectID] = order
        defaults.set(order.map(NSNumber.init(value:)), forKey: TerminalSessionOrder.key(workbenchID: projectID))
    }

    /// The full order a drag refills: the listed sessions in the panel's
    /// order, with the saved slot of each session waiting in the Undo batch
    /// kept (an Undo puts it back in place); ids of sessions gone are
    /// dropped.
    private func savedSlots(projectID: Int64?) -> [Int64] {
        let listed = orderedSessions(projectID: projectID).map(\.id)
        let kept = Set(listed).union(pendingDeletes.ids)
        let saved = sessionOrder(projectID: projectID).filter { kept.contains($0) }
        let placed = Set(saved)
        return listed.filter { !placed.contains($0) } + saved
    }

    /// Keeps the on-screen session's section (§3.3). Called when the page,
    /// the layout or the states change. A session newly on screen takes its
    /// real section — by its last read state, so opening (launching) a
    /// finished session does not count as resuming it; while it stays on
    /// screen a finish does not move it out of the main list, and a row back
    /// in the main list (a new prompt) anchors there again. Nothing is
    /// captured before the session has a state or runs: its section is not
    /// known yet. With no session on screen (Board, Files, another page) the
    /// kept section is dropped: a session shown again is decided afresh.
    func refreshStickySection() {
        guard let projectID = selectedWorkbenchID,
              case let .session(id)? = visibleSession(projectID: projectID) else {
            if stickySection != nil { stickySection = nil }
            return
        }
        let liveIDs = terminalCenter?.liveIDs ?? []
        let statuses = sessionStatuses
        guard statuses[id] != nil || liveIDs.contains(id) else { return }
        let real = SessionPanelSections.panelSection(of: id, liveIDs: liveIDs, statuses: statuses)
        guard stickySection?.sessionID != id || real == .main else { return }
        let next = SessionPanelSections.Sticky(sessionID: id, section: real)
        if stickySection != next { stickySection = next }
    }

    /// The kept section of the workbench's on-screen session, else its real
    /// one (a group row on screen is pinned under a folded header).
    private func panelSticky(projectID: Int64) -> SessionPanelSections.Sticky? {
        guard case let .session(id)? = visibleSession(projectID: projectID) else { return nil }
        if let kept = stickySection, kept.sessionID == id { return kept }
        let section = SessionPanelSections.panelSection(
            of: id, liveIDs: terminalCenter?.liveIDs ?? [], statuses: sessionStatuses
        )
        return SessionPanelSections.Sticky(sessionID: id, section: section)
    }
}
