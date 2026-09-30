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

    /// Level 2's sessions, most recently active first.
    var drilledSessions: [TerminalSession] {
        drilledProjectID.flatMap { terminalSessions[$0] } ?? []
    }

    var selectedStandalone: TerminalSession? {
        standaloneSessions.first { $0.id == selectedStandaloneID }
    }

    func isLive(_ session: TerminalSession) -> Bool {
        terminalCenter?.liveIDs.contains(session.id) ?? false
    }

    /// The session the project's terminal pane shows: the one last opened
    /// while it is open (so a session that exited keeps its exit bar on
    /// screen), else the most recently focused live one, else the most
    /// recently active open row.
    func shownSession(projectID: Int64) -> TerminalSession? {
        let rows = terminalSessions[projectID] ?? []
        if let id = shownSessionIDs[projectID], let row = rows.first(where: { $0.id == id && !$0.isClosed }) {
            return row
        }
        return terminalCenter?.activeSession(projectID: projectID) ?? rows.first { !$0.isClosed }
    }

    /// What level 2 highlights: the pane on screen, and for the terminal
    /// pane the session it shows.
    var panelSelection: WorkspacePane? {
        guard let drilledProjectID else { return nil }
        switch pane {
        case .board: return .board
        case .documents: return .documents
        case .terminal: return shownSession(projectID: drilledProjectID).map { .session($0.id) }
        }
    }

    /// A level-1 project click: selects it, which drills into it (the
    /// `selectedProjectID` observer). Nothing starts.
    func drill(into projectID: Int64) {
        selectedProjectID = projectID
    }

    /// A level-2 click. A session is opened (a closed one reopens, one not
    /// running starts) and shown in the terminal pane.
    func showFromPanel(_ item: WorkspacePane) async {
        guard let projectID = drilledProjectID else { return }
        switch item {
        case .board:
            showInLayout(.board, projectID: projectID)
            pane = .board
        case .documents:
            showInLayout(.documents, projectID: projectID)
            pane = .documents
        case let .session(id):
            pane = .terminal
            // The list may not be loaded yet (the panel loads it on appear).
            if terminalSessions[projectID]?.contains(where: { $0.id == id }) != true {
                await loadSessions(projectID: projectID)
            }
            guard let session = terminalSessions[projectID]?.first(where: { $0.id == id }) else {
                sessionActionErrors[projectID] = "That session no longer exists."
                return
            }
            await open(session)
        }
    }

    /// Level 2's "New session": a fresh `claude` session of the drilled
    /// project, shown in the terminal pane.
    func newPanelSession() async {
        guard let projectID = drilledProjectID else { return }
        pane = .terminal
        await newSession(projectID: projectID)
    }

    /// Puts `sessionID` in the project's terminal pane — e.g. the session a
    /// Send comments line was just pasted into, so the owner sees it land.
    func showTerminal(sessionID: Int64, projectID: Int64) {
        shownSessionIDs[projectID] = sessionID
        pane = .terminal
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

    private func showInLayout(_ item: WorkspacePane, projectID: Int64) {
        var updated = layout(projectID: projectID)
        updated.show(item)
        setLayout(updated, projectID: projectID)
    }
}
