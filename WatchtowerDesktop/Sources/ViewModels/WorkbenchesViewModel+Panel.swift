import Foundation
import WatchtowerCore

/// The Workbench tab's left panel (spec 2026-09-30-project-workspace-sessions
/// §3): level 1 lists projects and standalone terminals, level 2 one
/// project's Board, Files and sessions. The views only call these.
extension WorkbenchesViewModel {
    /// Level 2's project, when it is still listed.
    var drilledWorkbench: Workbench? {
        summaries.first { $0.id == drilledWorkbenchID }?.project
    }

    /// Level 2's sessions in the panel's order (`TerminalSessionOrder`).
    var drilledSessions: [TerminalSession] {
        drilledWorkbenchID.map { orderedSessions(projectID: $0) } ?? []
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
        defaults.set(order.map(NSNumber.init(value:)), forKey: TerminalSessionOrder.key(workbenchID: projectID))
    }

    /// Cached once dragged: UserDefaults is not observed, the cache is what
    /// re-renders the list after a drag.
    private func sessionOrder(projectID: Int64?) -> [Int64] {
        if let cached = sessionOrders[projectID] { return cached }
        let key = TerminalSessionOrder.key(workbenchID: projectID)
        guard let raw = defaults.array(forKey: key) else { return [] }
        let ids = raw.compactMap { ($0 as? NSNumber)?.int64Value }
        if ids.count != raw.count {
            NSLog("WorkbenchesViewModel: ignored %d unreadable entries in %@", raw.count - ids.count, key)
        }
        return ids
    }

    var selectedStandalone: TerminalSession? {
        standaloneSessions.first { $0.id == selectedStandaloneID }
    }

    /// The live sessions' agent statuses, for `SessionSwitcherPresentation.rows`.
    var sessionStatuses: [Int64: SessionAgentStatus] {
        agentStates?.statuses ?? [:]
    }

    /// `sessions` (in the panel's order) as the panel and the switchers
    /// show them: state, caption, `#id` badge.
    func sessionRows(_ sessions: [TerminalSession]) -> [SessionSwitcherPresentation.Row] {
        SessionSwitcherPresentation.rows(
            sessions, liveIDs: terminalCenter?.liveIDs ?? [], statuses: sessionStatuses, now: now()
        )
    }

    /// A session's dot: not started unless live, then what its workbench
    /// hooks report (board #312).
    func sessionState(_ session: TerminalSession) -> SessionSwitcherPresentation.State {
        SessionSwitcherPresentation.state(
            of: session.id, liveIDs: terminalCenter?.liveIDs ?? [], statuses: sessionStatuses
        )
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
        drilledWorkbenchID.flatMap(visibleSession(projectID:))
    }

    /// The collapsed header's session (board #251): the one on screen the
    /// way `panelSelection` picks it, else the workbench's active one. nil
    /// without a workbench page or when it has neither.
    var headerSession: TerminalSession? {
        guard let projectID = selectedWorkbenchID else { return nil }
        if case let .session(id)? = visibleSession(projectID: projectID), let row = session(id, projectID: projectID) {
            return row
        }
        return activeSessionID(projectID: projectID).flatMap { session($0, projectID: projectID) }
    }

    private func visibleSession(projectID: Int64) -> WorkspacePane? {
        let layout = layout(projectID: projectID)
        let candidates = layout.expanded.map { [$0] } ?? [layout.secondary, layout.primary].compactMap(\.self)
        return candidates.first { if case .session = $0 { true } else { false } }
    }

    /// A workbench page is on screen: ⌘1…⌘9 and ⌘T act on it.
    var hasWorkbenchPage: Bool {
        selectedWorkbench != nil
    }

    /// The workbench whose switchers the title row carries: only while the
    /// panel is hidden over its page (board #251, variant H).
    var headerSwitcherWorkbench: Workbench? {
        panelVisible ? nil : selectedWorkbench
    }

    /// A level-1 project click: selects it, which drills into it (the
    /// `selectedWorkbenchID` observer). Nothing starts.
    func drill(into projectID: Int64) {
        selectedWorkbenchID = projectID
    }

    /// A workbench picked in the switcher (board #250): drilled into, and
    /// its most recent session opened — the live one focused last, else the
    /// latest active (a `claude` row resumes). No sessions: its page alone,
    /// nothing starts. The workbench already on screen is left as it is;
    /// a panel at level 1 drills into it.
    func switchTo(workbenchID id: Int64) async {
        guard selectedWorkbenchID != id else {
            drill(into: id)
            return
        }
        drill(into: id)
        let ticket = beginSwitch(projectID: id)
        guard await loadSessions(projectID: id), selectedWorkbenchID == id else { return }
        let rows = terminalSessions[id] ?? []
        let active = activeSessionID(projectID: id)
        if let row = rows.first(where: { $0.id == active }) ?? rows.first { await open(row, ticket: ticket) }
    }

    /// The switcher's "All Workbenches": back to level 1, the panel
    /// shown if hidden; the page stays on screen.
    func showAllWorkbenches() {
        drilledWorkbenchID = nil
        panelVisible = true
    }

    /// ⌘1…⌘9: the n-th session of the workbench on screen, in the panel's
    /// order, opened like a panel click. Out of range, or no workbench
    /// page: nothing happens.
    func openSession(atShortcut n: Int) async {
        guard (1...SessionSwitcherPresentation.maxShortcut).contains(n), let projectID = selectedWorkbenchID else { return }
        let ticket = beginSwitch(projectID: projectID)
        // With the panel hidden nothing may have read the list yet.
        if terminalSessions[projectID] == nil {
            guard await loadSessions(projectID: projectID), selectedWorkbenchID == projectID else { return }
        }
        let rows = orderedSessions(projectID: projectID)
        guard n <= rows.count else { return }
        await showSession(id: rows[n - 1].id, ticket: ticket)
    }

    /// The workbench's sessions running in this app (`TerminalCenter`, not the DB).
    func liveSessionCount(workbenchID: Int64) -> Int {
        guard let terminalCenter else { return 0 }
        return terminalCenter.sessionIDs(ofWorkbench: workbenchID).intersection(terminalCenter.liveIDs).count
    }

    /// A level-2 click on a session — or a pick in the collapsed header's
    /// switcher, or ⌘N — in the workbench on screen: it is opened (one not
    /// running starts) and put on screen like any panel click.
    func showSession(id: Int64, ticket: Int? = nil) async {
        guard let projectID = selectedWorkbenchID else { return }
        let ticket = ticket ?? beginSwitch(projectID: projectID)
        // The list may not be loaded yet (the panel loads it on appear).
        // A failed load already reports itself; the row is not "gone".
        if terminalSessions[projectID]?.contains(where: { $0.id == id }) != true {
            // The owner may have moved to another page during the read.
            guard await loadSessions(projectID: projectID), selectedWorkbenchID == projectID else { return }
        }
        guard let session = terminalSessions[projectID]?.first(where: { $0.id == id }) else {
            reportSwitchError("That session no longer exists.", projectID: projectID, ticket: ticket)
            return
        }
        await open(session, ticket: ticket)
    }

    /// Level 2's "New session" (and ⌘T): a fresh `claude` session of the
    /// workbench on screen, put on screen like a panel click. The panel may
    /// be hidden or at level 1 (`drilledWorkbenchID` is nil or this one).
    func newSessionOnPage() async {
        guard let projectID = selectedWorkbenchID else { return }
        await newSession(projectID: projectID)
    }

    // MARK: - Main area (single / split / expand)

    /// The page's Split toggle. A split's second pane is Board when the
    /// first is a session, else the active live session, else whichever of
    /// Board and Files is not already shown. Nothing starts.
    func toggleSplit(projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        if updated.isSplit {
            updated.unsplit()
        } else if case .session = updated.primary {
            updated.split(with: .board)
        } else if let id = activeSessionID(projectID: projectID) {
            updated.split(with: .session(id))
        } else {
            updated.split(with: updated.primary == .board ? .files : .board)
        }
        setLayout(updated, projectID: projectID)
    }

    /// The page header's Terminal / Board / Files buttons. Board and Files
    /// never hide a terminal (`WorkspaceLayout.showWorkbenchView`).
    /// Terminal keeps the view on screen beside it in a split: a session
    /// already in a slot (or the live one) comes back as is; otherwise the
    /// most recent open session is resumed, or a new one starts.
    func showView(_ view: WorkspaceView, project: Workbench) async {
        var updated = layout(projectID: project.id)
        guard !updated.isShowing(view) else { return }
        switch view {
        case .board:
            updated.showWorkbenchView(.board)
        case .files:
            updated.showWorkbenchView(.files)
        case .terminal:
            let kept = updated.visiblePanes.first ?? updated.primary
            // `openMostRecentSession` takes its own ticket — past its
            // in-flight guard, so a repeated click never supersedes the
            // open it is waiting for.
            guard let id = updated.sessionIDs.first ?? activeSessionID(projectID: project.id) else {
                await openMostRecentSession(project: project, placement: .keeping(kept))
                return
            }
            updated.reveal(.session(id), keeping: kept)
        }
        beginSwitch(projectID: project.id)
        setLayout(updated, projectID: project.id)
    }

    /// A FILES tree click (POC): the file opens in a tab (a preview tab on a
    /// single click, a kept one on a double click) and the Files pane goes
    /// on screen the way the Board does — beside a terminal in a
    /// split, else in place.
    func openFile(_ relPath: String, project: Workbench, preview: Bool) async {
        // An edit still unsent in the preview tab keeps it before a preview
        // open could replace it.
        await codeFiles.pullPending(project)
        codeFiles.open(relPath, project: project, preview: preview)
        showFilesPane(projectID: project.id)
    }

    /// Open Quickly's ↩ and ⌥↩ (spec §8.1): the file in a preview tab, the
    /// cursor on the target's line (if any) and the keyboard in the editor
    /// once it shows. ↩ puts the Files pane on
    /// screen like a FILES click; ⌥↩ (`beside`) puts it beside the pane on
    /// screen, splitting a single pane (`WorkspaceLayout.openBeside`) — the
    /// Files pane alone stays alone (a workbench has one Files pane).
    func openFile(at target: OpenQuicklyTarget, project: Workbench, beside: Bool) async {
        await codeFiles.pullPending(project)
        codeFiles.open(target.path, project: project, preview: true)
        codeFiles.requestReveal(target.path, line: target.line, col: target.col, project: project)
        guard beside else {
            showFilesPane(projectID: project.id)
            return
        }
        var updated = layout(projectID: project.id)
        let kept = updated.visiblePanes.first { $0 != .files } ?? updated.primary
        updated.openBeside(.files, keeping: kept)
        setLayout(updated, projectID: project.id)
    }

    /// Go to definition and back/forward (spec §8.2): `location` in the Files
    /// pane, the cursor on its line and column. A jump (`keepingTab`) opens
    /// a kept tab — keeping a preview tab it lands on; back/forward
    /// activate the tab as it is, reopening a closed file as a kept tab.
    func showLocation(_ location: CodeNavLocation, project: Workbench, keepingTab: Bool) {
        if keepingTab || !codeFiles.tabs(for: project).contains(location.path) {
            codeFiles.open(location.path, project: project, preview: false)
        } else {
            codeFiles.activate(location.path, project: project)
        }
        codeFiles.requestReveal(location.path, line: location.line, col: location.col, project: project)
        showFilesPane(projectID: project.id)
    }

    /// The Files pane on screen, the way the header's Files button puts it.
    func showFilesPane(projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.showWorkbenchView(.files)
        setLayout(updated, projectID: projectID)
    }

    /// A header view button turned off: closes that pane of a split.
    func hideView(_ view: WorkspaceView, projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.hide(view)
        setLayout(updated, projectID: projectID)
    }

    /// A pane's own picker: `slot` shows `item` instead. A session is opened
    /// there (resumed if not running).
    func showInPane(_ slot: WorkspacePane, item: WorkspacePane, projectID: Int64) async {
        let ticket = beginSwitch(projectID: projectID)
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
            reportSwitchError("That session no longer exists.", projectID: projectID, ticket: ticket)
            return
        }
        await open(row, placement: .replacing(slot), ticket: ticket)
    }

    /// A pane picker's "New session": starts one in that pane.
    func newSession(inPane slot: WorkspacePane, projectID: Int64) async {
        await newSession(projectID: projectID, placement: .replacing(slot))
    }

    func toggleExpand(_ pane: WorkspacePane, projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.toggleExpand(pane)
        setLayout(updated, projectID: projectID)
    }

    func closePane(_ pane: WorkspacePane, projectID: Int64) {
        beginSwitch(projectID: projectID)
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
        selectedWorkbenchID = nil
        selectedStandaloneID = id
    }
}
