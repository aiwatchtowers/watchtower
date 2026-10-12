import SwiftUI
import WatchtowerCore

/// The left panel's level 2 (spec 2026-09-30-project-workspace-sessions §3):
/// one header row (the workbench switcher, New session), the owner asks
/// waiting (`OwnerAskStackSection`, spec 2026-10-03 Part 8), a SESSIONS label
/// in the app sidebar's style, then the project's sessions. The session on
/// screen is a tab of the workspace: filled with its backdrop, it runs on
/// into the page beside it (`panelTab(isSelected:)`, `panelSurface()`).
/// Board and Files are picked in a pane's own header (`WorkspacePaneView`).
struct WorkbenchSessionsPanel: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let actions: SessionRowActions
    let switcherActions: WorkbenchSwitcherActions
    /// View-local: it is only this list's scroll. The view keeps its identity
    /// when another workbench is opened, so `project.id` resets it.
    @State private var scroll = PanelSelectionScrollPolicy<Int64>()

    var body: some View {
        let sessions = vm.drilledSessions
        let stack = vm.asks.stack(projectID: project.id)
        let closed = vm.asks.closedCounts[project.id] ?? [:]
        let rows = vm.sessionRows(sessions)
        let rowIDs = rows.map(\.id)
        VStack(alignment: .leading, spacing: 0) {
            header
            OwnerAskStackSection(vm: vm, project: project)
            Text("SESSIONS")
                .sidebarSectionLabel()
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            // No List selection: its highlight would draw over the tab. The
            // tab follows `vm.panelSelection` (the session on screen) and a
            // row opens on its own click (`SessionRowActions.open`), which
            // also reaches the row already highlighted but not running
            // (VoiceOver has the row's action).
            // The list follows the session on screen, never the asks stack
            // above it (board #561): a new session is selected before its row
            // loads, so the policy keeps it pending until the row appears.
            ScrollViewReader { proxy in
                List {
                    ForEach(rows) { row in
                        TerminalSessionRow(
                            row: row,
                            actions: actions,
                            openAsks: stack.count(session: row.id),
                            reportLine: row.showsStateLabel ? vm.reportLine(sessionID: row.id, projectID: project.id) : nil,
                            reportProgress: row.showsStateLabel ? vm.reportProgress(sessionID: row.id, projectID: project.id) : nil,
                            closedAsks: (closed[row.id] ?? 0) > 0
                                ? OwnerAskClosedButton(vm: vm, projectID: project.id, sessionID: row.id, count: closed[row.id] ?? 0)
                                : nil
                        )
                        .panelTab(isSelected: vm.panelSelection == .session(row.id))
                    }
                    .onMove { vm.moveSessions(sessions, projectID: project.id, from: $0, to: $1) }
                }
                .clearPlainList()
                .onChange(of: selectedSessionID, initial: true) { _, id in
                    proxy.followSelection(scroll.panelScrollTarget(selecting: id, rows: rowIDs))
                }
                .onChange(of: rowIDs) { _, ids in
                    proxy.followSelection(scroll.panelScrollTarget(rows: ids))
                }
                // Same view, another workbench: start the policy afresh.
                .onChange(of: project.id) {
                    scroll = PanelSelectionScrollPolicy()
                    proxy.followSelection(scroll.panelScrollTarget(selecting: selectedSessionID, rows: rowIDs))
                }
            }
            WorkbenchFilesSection(vm: vm, root: project.mainCodeRoot)
        }
        .task(id: project.id) { await vm.sessionRowsAppeared(projectID: project.id) }
    }

    /// The session on screen, if the panel lists it (`.session` only).
    private var selectedSessionID: Int64? {
        if case let .session(id)? = vm.panelSelection { id } else { nil }
    }

    /// The chat history's header shape ("Chats" + New Chat), the title being
    /// the workbench switcher (board #250): it fills the width, and its
    /// popover's "All Workbenches" is the way back to level 1.
    private var header: some View {
        HStack(spacing: 6) {
            WorkbenchSwitcher(vm: vm, project: project, actions: switcherActions)
            // A click starts the default agent; the menu offers each agent.
            Menu {
                NewSessionMenuItems(vm: vm, projectID: project.id) { agent in
                    Task { await vm.newSessionOnPage(agent: agent) }
                }
            } label: {
                Image(systemName: "plus")
            } primaryAction: {
                Task { await vm.newSessionOnPage() }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New \(vm.defaultAgent.displayName) session — hold for the other agents")
            .accessibilityLabel("New session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// What a session row's click, Rename… and Delete… do; the page owns the
/// sheet and the confirmation (`sessionActionDialogs`).
struct SessionRowActions {
    let open: (TerminalSession) -> Void
    let rename: (TerminalSession) -> Void
    let delete: (TerminalSession) -> Void
}
