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

    /// A session list in the panel's order: stable while the owner switches
    /// sessions — opening one never moves it — and changed only by a drag.
    /// `projectID` nil = the standalone terminals.
    func orderedSessions(projectID: Int64?) -> [TerminalSession] {
        let rows = projectID.map { terminalSessions[$0] ?? [] } ?? standaloneSessions
        return TerminalSessionOrder.apply(rows, saved: sessionOrder(projectID: projectID))
    }

    /// Cached once dragged: UserDefaults is not observed, the cache is what
    /// re-renders the list after a drag.
    func sessionOrder(projectID: Int64?) -> [Int64] {
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

    /// The sessions' agent statuses, for `SessionSwitcherPresentation.rows`;
    /// a session waiting in the Undo batch has none (PROJ-17).
    var sessionStatuses: [Int64: SessionAgentStatus] {
        let statuses = agentStates?.statuses ?? [:]
        let hidden = pendingDeletes.ids
        return hidden.isEmpty ? statuses : statuses.filter { !hidden.contains($0.key) }
    }

    /// A session's dot: not started unless live, then what its workbench
    /// hooks report (board #312).
    func sessionState(_ session: TerminalSession) -> SessionSwitcherPresentation.State {
        SessionSwitcherPresentation.state(
            of: session.id, liveIDs: terminalCenter?.liveIDs ?? [], statuses: sessionStatuses
        )
    }

    /// Whether a live session's agent sits at its prompt after a turn of
    /// this run (`SessionAgentStatus.isAtPrompt`).
    func isSessionAtPrompt(_ session: TerminalSession) -> Bool {
        guard terminalCenter?.liveIDs.contains(session.id) == true else { return false }
        return sessionStatuses[session.id]?.isAtPrompt == true
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

    /// The page's session (board #251): the one on screen the way
    /// `panelSelection` picks it, else the workbench's active one. nil
    /// without a workbench page or when it has neither.
    var headerSession: TerminalSession? {
        guard let projectID = selectedWorkbenchID else { return nil }
        if case let .session(id)? = visibleSession(projectID: projectID), let row = session(id, projectID: projectID) {
            return row
        }
        return activeSessionID(projectID: projectID).flatMap { session($0, projectID: projectID) }
    }

    /// The session on screen as `.session(id)`, in its terminal or its
    /// Workchat (#711).
    func visibleSession(projectID: Int64) -> WorkspacePane? {
        visibleSessionPane(projectID: projectID).flatMap(WorkspaceLayout.sessionID(of:)).map { .session($0) }
    }

    /// The pane — a terminal or a Workchat — `visibleSession` picks.
    func visibleSessionPane(projectID: Int64) -> WorkspacePane? {
        let layout = layout(projectID: projectID)
        let candidates = layout.expanded.map { [$0] } ?? [layout.secondary, layout.primary].compactMap(\.self)
        return candidates.first { WorkspaceLayout.sessionID(of: $0) != nil }
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
        // Coming back to a workbench whose page screen is open is not a
        // pick: the screen stays, over the workspace as it was (spec
        // 2026-10-26 §3.1).
        guard !pageCovered(projectID: id) else { return }
        let rows = terminalSessions[id] ?? []
        let active = activeSessionID(projectID: id)
        if let row = rows.first(where: { $0.id == active }) ?? rows.first { await open(row, ticket: ticket) }
    }

    /// The switcher's "All Workbenches" — and the back button, ⌘[ and the
    /// swipe (board #743): back to level 1, the panel shown if hidden; the
    /// page stays on screen.
    func showAllWorkbenches() {
        drilledWorkbenchID = nil
        panelVisible = true
    }

    /// Whether the workbench list is off screen — the panel at level 2, or
    /// hidden — so the way back to it (board #743) has somewhere to go.
    var canShowAllWorkbenches: Bool {
        drilledWorkbenchID != nil || !panelVisible
    }

    /// The workbench's sessions whose agent works now — a turn running, or
    /// background agents after it — as the sessions panel shows them
    /// (`sessionStatuses`: live sessions, none in the Undo batch). A live
    /// session waiting at its prompt does not count.
    func workingSessionCount(workbenchID: Int64) -> Int {
        sessionStatuses.values.filter { status in
            status.workbenchID == workbenchID && ReviewChangesModel.agentWorkingKinds.contains(status.state.kind)
        }.count
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

    /// The page header's Terminal / Session / Board / Files buttons. Session,
    /// Board and Files never hide a terminal (`WorkspaceLayout.showWorkbenchView`).
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
        case .analytics:
            updated.showWorkbenchView(.analytics)
        case .chat where !updated.isSplit:
            // The twin switch's Workchat half: the session's Workchat in
            // place of the pane on screen, its mode recorded (#711).
            guard let id = sessionViewTarget(projectID: project.id) else { return }
            updated.setMode(true, sessionID: id)
            updated.show(.sessionChat(id))
        case .report, .changes, .chat:
            guard let id = sessionViewTarget(projectID: project.id) else { return }
            let pane: WorkspacePane = switch view {
            case .report: .sessionReport(id)
            case .chat: .sessionChat(id)
            default: .changes(id)
            }
            Self.placeBesideItsSession(pane, sessionID: id, in: &updated)
        case .terminal where !updated.isSplit && updated.primary.isWorkchat:
            // The twin switch's Terminal half over a Workchat: its own
            // session's terminal, in place (#711).
            guard let id = WorkspaceLayout.sessionID(of: updated.primary) else { return }
            updated.toggleMode(sessionID: id)
        case .terminal:
            let id = updated.sessionIDs.first ?? updated.shownSessionIDs.first ?? activeSessionID(projectID: project.id)
            // A Workchat on screen stays beside its session's terminal.
            let kept = id.flatMap { id in updated.visiblePanes.first { $0 == .sessionChat(id) } }
                ?? updated.visiblePanes.first ?? updated.primary
            // `openMostRecentSession` takes its own ticket — past its
            // in-flight guard, so a repeated click never supersedes the
            // open it is waiting for. It opens the session in its recorded mode.
            guard let id else {
                await openMostRecentSession(project: project, placement: .keeping(kept))
                return
            }
            Self.revealTerminal(id, keeping: kept, in: &updated)
        }
        beginSwitch(projectID: project.id)
        setLayout(updated, projectID: project.id)
    }

    /// Session `id`'s terminal on screen beside `kept`, and Terminal its
    /// mode from now on — unless its Workchat stays beside it.
    private static func revealTerminal(_ id: Int64, keeping kept: WorkspacePane, in layout: inout WorkspaceLayout) {
        if kept != .sessionChat(id) { layout.setMode(false, sessionID: id) }
        layout.reveal(.session(id), keeping: kept)
    }

    /// The session the Session and Changes views open on: the one on screen,
    /// else the active one, else the first listed agent session; nil = none,
    /// nothing to report on or review (`showView(.report / .changes)` then
    /// changes nothing).
    func sessionViewTarget(projectID: Int64) -> Int64? {
        layout(projectID: projectID).shownSessionIDs.first ?? activeSessionID(projectID: projectID)
            ?? orderedSessions(projectID: projectID).first { $0.kind.isAgent }?.id
    }

    /// A session row's Review Changes (board #328): its workbench on screen,
    /// the session's Changes pane beside its terminal, the way the header's
    /// Changes button puts it.
    func showChanges(sessionID: Int64, projectID: Int64) {
        if selectedWorkbenchID != projectID { selectedWorkbenchID = projectID }
        showBesideItsSession(.changes(sessionID), sessionID: sessionID, projectID: projectID)
    }

    /// A session strip's Report or Changes (spec 2026-10-20, call 8): that
    /// session's `pane` beside its own terminal, the way the header's
    /// toggle puts the shown session's.
    func showBesideItsSession(_ pane: WorkspacePane, sessionID: Int64, projectID: Int64) {
        beginSwitch(projectID: projectID)
        closePageScreen(projectID: projectID)
        var updated = layout(projectID: projectID)
        Self.placeBesideItsSession(pane, sessionID: sessionID, in: &updated)
        setLayout(updated, projectID: projectID)
    }

    /// A session strip's Terminal or Workchat over that session's report or
    /// Changes: the slot shows the session instead, in that mode — recorded
    /// as the mode it opens in — resumed if not running. The open places the
    /// session by its recorded mode, so the mode is written first; an open
    /// that does not put the session on screen (it was deleted, its row
    /// could not be read) gives the previous mode back, so only an open that
    /// succeeded keeps it.
    func showSession(_ id: Int64, workchat: Bool, inPane slot: WorkspacePane, projectID: Int64) async {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        let previous = updated.pane(forSession: id).isWorkchat
        updated.setMode(workchat, sessionID: id)
        setLayout(updated, projectID: projectID)
        await showInPane(slot, item: .session(id), projectID: projectID)
        var after = layout(projectID: projectID)
        guard !after.showsSession(id), after.pane(forSession: id).isWorkchat == workchat else { return }
        after.setMode(previous, sessionID: id)
        setLayout(after, projectID: projectID)
    }

    /// A session row's Open in Workchat (#711): its workbench on screen and
    /// the session opened like a panel click, in its Workchat — the mode it
    /// opens in from now on.
    func showWorkchat(sessionID: Int64, projectID: Int64) async {
        await showSession(sessionID, workchat: true, projectID: projectID)
    }

    /// A session row's Open in Terminal (#711): `showWorkchat`'s pair.
    func showTerminal(sessionID: Int64, projectID: Int64) async {
        await showSession(sessionID, workchat: false, projectID: projectID)
    }

    /// The Workchat's Show in Terminal (#711): the session's terminal on
    /// screen, recorded as its mode. A Workchat in a slot swaps to it in
    /// place; a terminal already on screen stays; otherwise the session
    /// opens like a panel click.
    func showTerminalFromWorkchat(sessionID id: Int64, projectID: Int64) async {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        guard !updated.visiblePanes.contains(.session(id)) else { return }
        guard updated.primary == .sessionChat(id) || updated.secondary == .sessionChat(id) else {
            await showTerminal(sessionID: id, projectID: projectID)
            return
        }
        updated.toggleMode(sessionID: id)
        setLayout(updated, projectID: projectID)
    }

    private func showSession(_ id: Int64, workchat: Bool, projectID: Int64) async {
        if selectedWorkbenchID != projectID { selectedWorkbenchID = projectID }
        var updated = layout(projectID: projectID)
        updated.setMode(workchat, sessionID: id)
        setLayout(updated, projectID: projectID)
        await showSession(id: id)
    }

    /// The session ⌃` acts on: the one on screen, when the toggle would
    /// change what is on screen (not with both its modes side by side).
    func workchatToggleSession(projectID: Int64) -> Int64? {
        guard let id = visibleSessionPane(projectID: projectID).flatMap(WorkspaceLayout.sessionID(of:)),
              layout(projectID: projectID).togglesVisibly(sessionID: id) else { return nil }
        return id
    }

    /// ⌃` and the View menu's Show Terminal / Show Workchat (#711): the
    /// session on screen swaps its terminal and its Workchat in place.
    /// No session on screen, or both its modes side by side: nothing changes.
    func toggleWorkchat(projectID: Int64) {
        guard let id = workchatToggleSession(projectID: projectID) else { return }
        toggleMode(sessionID: id, projectID: projectID)
    }

    /// ⌃` and a session strip's Terminal | Workchat (spec 2026-10-20, call
    /// 8): the slot holding session `id` shows its other mode, in place —
    /// the other pane of a split stays — and that mode is recorded.
    func toggleMode(sessionID id: Int64, projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.toggleMode(sessionID: id)
        setLayout(updated, projectID: projectID)
    }

    /// The session's Changes pane model, made once per session; nil without
    /// the watchtower CLI (the review runs through `workbench review …`).
    func reviewModel(sessionID: Int64, projectID: Int64) -> ReviewChangesModel? {
        if let model = reviewModels[sessionID] { return model }
        guard let cli else { return nil }
        let model = ReviewChangesModel(
            projectID: projectID, sessionID: sessionID, cli: cli, db: dbPool, lineDelivery: lineDelivery
        ) { [weak self] in
            guard let self else { return false }
            return ReviewChangesModel.agentWorks(
                sessionID: sessionID, liveIDs: self.terminalCenter?.liveIDs ?? [], statuses: self.sessionStatuses
            )
        }
        reviewModels[sessionID] = model
        return model
    }

    /// The session's Workchat composer, made once per session; nil without
    /// the app's `SessionControl` (a test VM).
    func workchat(sessionID: Int64) -> WorkchatModel? {
        if let model = workchatModels[sessionID] { return model }
        guard let sessionControl else { return nil }
        let model = WorkchatModel(
            sessionID: sessionID, control: sessionControl, lineDelivery: lineDelivery, attachmentStore: attachmentStore
        ) { [weak self] in
            self?.terminalSessions.values.lazy.flatMap { $0 }.first { $0.id == sessionID }?.kind
        }
        workchatModels[sessionID] = model
        return model
    }

    /// The workbench's Find Repeats model, made once; nil without the watchtower CLI.
    func reviewLessonsModel(projectID: Int64) -> ReviewLessonsModel? {
        if let model = reviewLessonModels[projectID] { return model }
        guard let cli else { return nil }
        let model = ReviewLessonsModel(projectID: projectID, cli: cli, db: dbPool)
        reviewLessonModels[projectID] = model
        return model
    }

    /// A session's report, Changes or Workchat beside its own session's
    /// terminal or Workchat (board #357, #711): a split showing that session
    /// keeps its pane and swaps the other one — whichever slot holds it, so
    /// the second session of a split gets its report beside its own
    /// terminal (spec 2026-10-20, call 8); otherwise the page becomes the
    /// session — its Workchat on screen stays, else its terminal — and
    /// `pane` side by side, so a panel click re-points the report instead
    /// of replacing it. Nothing starts.
    private static func placeBesideItsSession(_ pane: WorkspacePane, sessionID id: Int64, in layout: inout WorkspaceLayout) {
        let own = layout.visiblePanes.first { $0 != pane && WorkspaceLayout.sessionID(of: $0) == id }
        if layout.isSplit, let own {
            layout.reveal(pane, keeping: own)
        } else {
            layout.primary = own ?? .session(id)
            layout.split(with: pane)
        }
    }

    /// A FILES tree click (POC): the file opens in a tab (a preview tab on a
    /// single click, a kept one on a double click) and the Files pane goes
    /// on screen the way the Board does — beside a terminal in a
    /// split, else in place.
    func openFile(_ relPath: String, root: CodeRoot, preview: Bool) async {
        // An edit still unsent in the preview tab keeps it before a preview
        // open could replace it.
        await codeFiles.pullPending(root)
        codeFiles.open(relPath, root: root, preview: preview)
        showFilesPane(projectID: root.workbenchID)
    }

    /// Open Quickly's ↩ and ⌥↩ (spec §8.1): the file in a preview tab, the
    /// cursor on the target's line (if any) and the keyboard in the editor
    /// once it shows. ↩ puts the Files pane on
    /// screen like a FILES click; ⌥↩ (`beside`) puts it beside the pane on
    /// screen, splitting a single pane (`WorkspaceLayout.openBeside`) — the
    /// Files pane alone stays alone (a workbench has one Files pane).
    /// The key Branch review pane takes the pick instead (board #960).
    func openFile(at target: OpenQuicklyTarget, root: CodeRoot, beside: Bool) async {
        let location = CodeNavLocation(path: target.path, line: target.line ?? 0, col: target.col ?? 1)
        if let destination = keyDestination(for: root), destination.show(location, root: root) { return }
        await codeFiles.pullPending(root)
        codeFiles.open(target.path, root: root, preview: true)
        codeFiles.requestReveal(target.path, line: target.line, col: target.col, root: root)
        guard beside else {
            showFilesPane(projectID: root.workbenchID)
            return
        }
        var updated = layout(projectID: root.workbenchID)
        let kept = updated.visiblePanes.first { $0 != .files } ?? updated.primary
        updated.openBeside(.files, keeping: kept)
        setLayout(updated, projectID: root.workbenchID)
    }

    /// A ⌘-clicked `path:line` in a workbench session's terminal (spec
    /// §9.5): the file in Files at the line, beside the terminal (⌥↩'s
    /// placement). A workbench no longer listed opens nothing.
    /// It opens in the root of the session it was clicked in (its worktree
    /// when proven, else the main folder) — the root the page shows once
    /// that session is on screen.
    func openTerminalLink(_ location: TerminalPathLinks.Location, workbenchID: Int64, sessionID: Int64) async {
        guard let project = summaries.first(where: { $0.id == workbenchID })?.project else { return }
        let target = OpenQuicklyTarget(path: location.path, line: location.line, col: location.col)
        await openFile(at: target, root: codeRoot(sessionID: sessionID, project: project), beside: true)
    }

    /// The folder a session's ⌘-clicked `path:line` resolves in: the root
    /// `openTerminalLink` opens it in, so a file only the session's worktree
    /// has is a link (board #565). nil for a workbench no longer listed.
    func terminalLinkFolder(workbenchID: Int64, sessionID: Int64) -> String? {
        guard let project = summaries.first(where: { $0.id == workbenchID })?.project else { return nil }
        return codeRoot(sessionID: sessionID, project: project).folder.path
    }

    /// Go to definition and back/forward (spec §8.2): `location` in the Files
    /// pane, the cursor on its line and column. A jump (`keepingTab`) opens
    /// a kept tab — keeping a preview tab it lands on; back/forward
    /// activate the tab as it is, reopening a closed file as a kept tab.
    /// The key Branch review pane takes it instead (board #960).
    func showLocation(_ location: CodeNavLocation, root: CodeRoot, keepingTab: Bool) {
        if let destination = keyDestination(for: root), destination.show(location, root: root) { return }
        if keepingTab || !codeFiles.tabs(for: root).contains(location.path) {
            codeFiles.open(location.path, root: root, preview: false)
        } else {
            codeFiles.activate(location.path, root: root)
        }
        codeFiles.requestReveal(location.path, line: location.line, col: location.col, root: root)
        showFilesPane(projectID: root.workbenchID)
    }

    /// A Branch review pane came on screen: while it is key, jumps in its
    /// root land in it (board #960).
    func registerDestination(_ destination: CodeLocationDestination, workbenchID: Int64) {
        var list = codeDestinations[workbenchID, default: []].filter { $0.destination != nil && $0.destination !== destination }
        list.append(WeakCodeLocationDestination(destination: destination))
        codeDestinations[workbenchID] = list
    }

    func unregisterDestination(_ destination: CodeLocationDestination, workbenchID: Int64) {
        let list = codeDestinations[workbenchID, default: []].filter { $0.destination != nil && $0.destination !== destination }
        codeDestinations[workbenchID] = list.isEmpty ? nil : list
    }

    /// The registered pane that is key and shows `root`; nil = the Files
    /// pane takes the jump (Review Focus 4).
    func keyDestination(for root: CodeRoot) -> CodeLocationDestination? {
        codeDestinations[root.workbenchID]?.lazy.compactMap(\.destination).first { $0.isKeyDestination && $0.root == root }
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

    /// The title row's Session tab turned on (spec 2026-10-20 call 7): the
    /// session view target in the mode it was last shown in — its Workchat
    /// or its terminal — the way today's Workchat / Terminal buttons put it
    /// (`showView`). In a split a Workchat takes the second pane and the
    /// first stays, as the terminal does (`revealTerminal`). With no
    /// session, Terminal's path.
    func showSessionTab(project: Workbench) async {
        var updated = layout(projectID: project.id)
        guard let id = sessionViewTarget(projectID: project.id), updated.pane(forSession: id).isWorkchat else {
            await showView(.terminal, project: project)
            return
        }
        guard updated.isSplit else {
            await showView(.chat, project: project)
            return
        }
        updated.reveal(.sessionChat(id), keeping: updated.visiblePanes.first ?? updated.primary)
        beginSwitch(projectID: project.id)
        setLayout(updated, projectID: project.id)
    }

    /// The Session tab turned off: a split's session pane closes, the other
    /// pane stays alone (`WorkspaceLayout.hideSessionViews`).
    func hideSessionViews(projectID: Int64) {
        beginSwitch(projectID: projectID)
        var updated = layout(projectID: projectID)
        updated.hideSessionViews()
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
