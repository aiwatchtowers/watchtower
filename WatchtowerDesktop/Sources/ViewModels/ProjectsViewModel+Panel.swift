import Foundation
import WatchtowerCore

/// The Projects tab's left panel (spec 2026-09-30-project-workspace-sessions
/// §3): level 1 lists projects and standalone terminals, level 2 one
/// project's Board, Documents and sessions. The views only call these.
extension ProjectsViewModel {
    /// Level 2's project, when it is still listed.
    var drilledProject: Project? {
        summaries.first { $0.id == drilledProjectID }?.project
    }

    /// Level 2's sessions in the panel's order (`TerminalSessionOrder`).
    var drilledSessions: [TerminalSession] {
        drilledProjectID.map { orderedSessions(projectID: $0) } ?? []
    }

    /// A session list in the panel's order: stable while the owner switches
    /// sessions — opening one never moves it — and changed only by a drag.
    /// `projectID` nil = the standalone terminals.
    func orderedSessions(projectID: Int64?) -> [TerminalSession] {
        let rows = projectID.map { terminalSessions[$0] ?? [] } ?? standaloneSessions
        return TerminalSessionOrder.apply(rows, saved: sessionOrder(projectID: projectID))
    }

    /// A drag in a session list; the new order is saved for that list.
    /// `displayed` is the list the drag's offsets index — the one the view
    /// rendered, not a re-read that a reload may have changed meanwhile.
    func moveSessions(_ displayed: [TerminalSession], projectID: Int64?, from source: IndexSet, to destination: Int) {
        let order = TerminalSessionOrder.move(displayed, from: source, to: destination)
        sessionOrders[projectID] = order
        defaults.set(order.map(NSNumber.init(value:)), forKey: TerminalSessionOrder.key(projectID: projectID))
    }

    /// Cached once dragged: UserDefaults is not observed, the cache is what
    /// re-renders the list after a drag.
    private func sessionOrder(projectID: Int64?) -> [Int64] {
        if let cached = sessionOrders[projectID] { return cached }
        let key = TerminalSessionOrder.key(projectID: projectID)
        guard let raw = defaults.array(forKey: key) else { return [] }
        let ids = raw.compactMap { ($0 as? NSNumber)?.int64Value }
        if ids.count != raw.count {
            NSLog("ProjectsViewModel: ignored %d unreadable entries in %@", raw.count - ids.count, key)
        }
        return ids
    }

    var selectedStandalone: TerminalSession? {
        standaloneSessions.first { $0.id == selectedStandaloneID }
    }

    func isLive(_ session: TerminalSession) -> Bool {
        terminalCenter?.liveIDs.contains(session.id) ?? false
    }

    /// A session pane's row; nil once the row is gone (the next load drops
    /// it from the layout).
    func session(_ id: Int64, projectID: Int64) -> TerminalSession? {
        terminalSessions[projectID]?.first { $0.id == id }
    }

    /// What level 2 highlights: the session on screen — the expanded pane,
    /// else the pane the last panel click filled (the secondary of a split),
    /// else the other one. nil when no session is visible (the panel lists
    /// only sessions).
    var panelSelection: WorkspacePane? {
        guard let drilledProjectID else { return nil }
        let layout = layout(projectID: drilledProjectID)
        let candidates = layout.expanded.map { [$0] } ?? [layout.secondary, layout.primary].compactMap(\.self)
        return candidates.first { if case .session = $0 { true } else { false } }
    }

    /// A level-1 project click: selects it, which drills into it (the
    /// `selectedProjectID` observer). Nothing starts.
    func drill(into projectID: Int64) {
        selectedProjectID = projectID
    }

    /// A level-2 click on a session: it is opened (a closed one reopens, one
    /// not running starts) and put on screen like any panel click.
    func showFromPanel(sessionID id: Int64) async {
        guard let projectID = drilledProjectID else { return }
        // The list may not be loaded yet (the panel loads it on appear).
        // A failed load already reports itself; the row is not "gone".
        if terminalSessions[projectID]?.contains(where: { $0.id == id }) != true {
            guard await loadSessions(projectID: projectID) else { return }
        }
        guard let session = terminalSessions[projectID]?.first(where: { $0.id == id }) else {
            sessionActionErrors[projectID] = "That session no longer exists."
            return
        }
        await open(session)
    }

    /// Level 2's "New session": a fresh `claude` session of the drilled
    /// project, put on screen like a panel click.
    func newPanelSession() async {
        guard let projectID = drilledProjectID else { return }
        await newSession(projectID: projectID)
    }

    /// Puts `sessionID` on screen the way `Placement.keeping(.documents)`
    /// does — the session a Send comments line was just pasted into, so the
    /// owner sees it land: beside the document in a split (already visible →
    /// nothing moves), in its place in a single pane.
    func showTerminal(sessionID: Int64, projectID: Int64) {
        var updated = layout(projectID: projectID)
        updated.reveal(.session(sessionID), keeping: .documents)
        setLayout(updated, projectID: projectID)
    }

    // MARK: - Main area (single / split / expand)

    /// The page's Split toggle. A split's second pane is Board when the
    /// first is a session, else the active live session, else whichever of
    /// Board and Documents is not already shown. Nothing starts.
    func toggleSplit(projectID: Int64) {
        var updated = layout(projectID: projectID)
        if updated.isSplit {
            updated.unsplit()
        } else if case .session = updated.primary {
            updated.split(with: .board)
        } else if let id = activeSessionID(projectID: projectID) {
            updated.split(with: .session(id))
        } else {
            updated.split(with: updated.primary == .board ? .documents : .board)
        }
        setLayout(updated, projectID: projectID)
    }

    /// A pane's own picker: `slot` shows `item` instead. A session is opened
    /// there (reopened if closed, resumed if not running).
    func showInPane(_ slot: WorkspacePane, item: WorkspacePane, projectID: Int64) async {
        guard case let .session(id) = item else {
            var updated = layout(projectID: projectID)
            updated.replace(slot, with: item)
            setLayout(updated, projectID: projectID)
            return
        }
        if session(id, projectID: projectID) == nil {
            guard await loadSessions(projectID: projectID) else { return }
        }
        guard let row = session(id, projectID: projectID) else {
            sessionActionErrors[projectID] = "That session no longer exists."
            return
        }
        await open(row, placement: .replacing(slot))
    }

    /// A pane picker's "New session": starts one in that pane.
    func newSession(inPane slot: WorkspacePane, projectID: Int64) async {
        await newSession(projectID: projectID, placement: .replacing(slot))
    }

    func toggleExpand(_ pane: WorkspacePane, projectID: Int64) {
        var updated = layout(projectID: projectID)
        updated.toggleExpand(pane)
        setLayout(updated, projectID: projectID)
    }

    func closePane(_ pane: WorkspacePane, projectID: Int64) {
        var updated = layout(projectID: projectID)
        updated.remove(pane)
        setLayout(updated, projectID: projectID)
    }

    /// The divider's position, saved when a drag ends.
    func setDividerFraction(_ fraction: Double, projectID: Int64) {
        var updated = layout(projectID: projectID)
        updated.setDividerFraction(fraction)
        setLayout(updated, projectID: projectID)
    }

    /// A standalone terminal takes the whole page, single pane (spec §3).
    func selectStandalone(_ session: TerminalSession) async {
        showStandalone(session.id)
        await open(session)
    }

    /// Puts a standalone terminal on screen instead of any project.
    func showStandalone(_ id: Int64) {
        selectedProjectID = nil
        selectedStandaloneID = id
    }

}
