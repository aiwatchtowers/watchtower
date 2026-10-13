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
        let sections = vm.panelSections(projectID: project.id)
        let scrollIDs = sections.panelScrollIDs
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
            // loads, so the policy keeps it pending until the row appears. A
            // row under the finished group's header brings the header in too.
            ScrollViewReader { proxy in
                List {
                    sessionList(sections)
                }
                .clearPlainList()
                .onChange(of: selectedSessionID, initial: true) { _, id in
                    let target = scroll.panelScrollTarget(selecting: id, rows: scrollIDs)
                    proxy.followSelection(along: sections.panelScrollPath(to: target))
                }
                .onChange(of: scrollIDs) { _, ids in
                    proxy.followSelection(along: sections.panelScrollPath(to: scroll.panelScrollTarget(rows: ids)))
                }
                // An opened group shows from its header down, as far as it fits.
                .onChange(of: sections.expanded) { _, expanded in
                    guard expanded, let last = sections.finished.last else { return }
                    proxy.followSelection(along: [last.id, SessionPanelSections.groupHeaderScrollID])
                }
                // Same view, another workbench: start the policy afresh.
                .onChange(of: project.id) {
                    scroll = PanelSelectionScrollPolicy()
                    let target = scroll.panelScrollTarget(selecting: selectedSessionID, rows: scrollIDs)
                    proxy.followSelection(along: sections.panelScrollPath(to: target))
                }
            }
            WorkbenchFilesSection(vm: vm, root: project.mainCodeRoot)
        }
        .task(id: project.id) { await vm.sessionRowsAppeared(projectID: project.id) }
    }

    /// The main list (drag to reorder), then the "▸ N finished" header and
    /// the open group's rows or the on-screen row pinned under a folded
    /// header (board #480). Rows drag within the main list only.
    @ViewBuilder
    private func sessionList(_ sections: SessionPanelSections) -> some View {
        let stack = vm.asks.stack(projectID: project.id)
        let closed = vm.asks.closedCounts[project.id] ?? [:]
        let mainSessions = sections.main.map(\.session)
        ForEach(sections.main) { row in
            SessionsPanelSessionRow(
                vm: vm, projectID: project.id, row: row, actions: actions,
                openAsks: stack.count(session: row.id), closedAsks: closed[row.id] ?? 0
            )
        }
        .onMove { vm.moveSessions(mainSessions, projectID: project.id, from: $0, to: $1) }
        if sections.finishedCount > 0 {
            SessionsPanelFinishedHeader(count: sections.finishedCount, expanded: sections.expanded) {
                vm.setFinishedGroupExpanded(!sections.expanded, projectID: project.id)
            }
            .id(SessionPanelSections.groupHeaderScrollID)
            ForEach(sections.finished + (sections.pinned.map { [$0] } ?? [])) { row in
                SessionsPanelSessionRow(
                    vm: vm, projectID: project.id, row: row, actions: actions,
                    openAsks: stack.count(session: row.id), closedAsks: closed[row.id] ?? 0
                )
            }
        }
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
