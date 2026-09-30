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

    /// What level 2 highlights: the pane on screen, and for the terminal
    /// pane the session it shows. nil while another project is selected.
    var panelSelection: WorkspacePane? {
        guard let drilledProjectID, drilledProjectID == selectedProjectID else { return nil }
        switch pane {
        case .board: return .board
        case .documents: return .documents
        case .terminal:
            let shown = activeSessionID(projectID: drilledProjectID)
                ?? terminalSessions[drilledProjectID]?.first { !$0.isClosed }?.id
            return shown.map(WorkspacePane.session)
        }
    }

    /// A level-1 project click: selects it and drills into it. Nothing starts.
    func drill(into projectID: Int64) {
        selectedProjectID = projectID
        drilledProjectID = projectID
    }

    /// A level-2 click. A session is opened (a closed one reopens, one not
    /// running starts) and shown in the terminal pane.
    func showFromPanel(_ item: WorkspacePane) async {
        guard let projectID = drilledProjectID else { return }
        if selectedProjectID != projectID { selectedProjectID = projectID }
        switch item {
        case .board, .documents:
            var updated = layout(projectID: projectID)
            updated.show(item)
            setLayout(updated, projectID: projectID)
            pane = item == .board ? .board : .documents
        case let .session(id):
            // The list may not be loaded yet (the panel loads it on appear).
            if terminalSessions[projectID]?.contains(where: { $0.id == id }) != true {
                await loadSessions(projectID: projectID)
            }
            guard let session = terminalSessions[projectID]?.first(where: { $0.id == id }) else { return }
            pane = .terminal
            await open(session)
        }
    }

    /// Level 2's "New session": a fresh `claude` session of the drilled
    /// project, shown in the terminal pane.
    func newPanelSession() async {
        guard let projectID = drilledProjectID else { return }
        if selectedProjectID != projectID { selectedProjectID = projectID }
        pane = .terminal
        await newSession(projectID: projectID)
    }

    /// A standalone terminal takes the whole page, single pane (spec §3).
    func selectStandalone(_ session: TerminalSession) async {
        selectedProjectID = nil
        selectedStandaloneID = session.id
        await open(session)
    }
}
