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
    /// The panel holds the keyboard (`SessionsPanelKeyView`, board #480).
    @State private var hasKeyboard = false
    /// The row under the mouse: its ✕ shows.
    @State private var hoveredRow: Int64?

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
                .contentShape(Rectangle())
                .onTapGesture { vm.requestPanelKeyboard() }
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
                // ↑ ↓ Return Esc ⌘⌫ ⌘Z once a click on the list's empty
                // space, the label, the group header, a ✕ or Undo gave the
                // panel the keyboard; a row click still sends it into the
                // terminal (ask #195).
                .sessionsPanelKeys(vm: vm, projectID: project.id, actions: actions, hasKeyboard: $hasKeyboard)
                .onChange(of: vm.panelCursor) { _, id in
                    guard hasKeyboard else { return }
                    proxy.followSelection(along: sections.panelScrollPath(to: id))
                }
                .onChange(of: selectedSessionID, initial: true) { _, id in
                    let target = scroll.panelScrollTarget(selecting: id, rows: scrollIDs)
                    proxy.followSelection(along: sections.panelScrollPath(to: target))
                }
                .onChange(of: scrollIDs) { _, ids in
                    proxy.followSelection(along: sections.panelScrollPath(to: scroll.panelScrollTarget(rows: ids)))
                }
                // The selected row moved between the group and the main list
                // with no new selection (a pinned row resumed): follow it.
                .onChange(of: sections.panelScrollPath(to: selectedSessionID)) { old, new in
                    guard PanelSelectionScrollPolicy<Int64>.movedSelection(from: old, to: new) != nil else { return }
                    proxy.followSelection(along: new)
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
            // The delete's Undo in its own bar under the list: it covers no
            // row and no FILES tree, and a click on it is not a click on
            // the list's empty space (only Undo hands the panel the keyboard).
            SessionDeleteToast(vm: vm)
            WorkbenchFilesSection(vm: vm, root: vm.activeCodeRoot(project: project))
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
                openAsks: stack.count(session: row.id), closedAsks: closed[row.id] ?? 0,
                hoveredRow: $hoveredRow, panelHasKeyboard: hasKeyboard
            )
        }
        .onMove { vm.moveSessions(mainSessions, projectID: project.id, from: $0, to: $1) }
        if sections.finishedCount > 0 {
            SessionsPanelFinishedHeader(count: sections.finishedCount, expanded: sections.expanded) {
                vm.setFinishedGroupExpanded(!sections.expanded, projectID: project.id)
                vm.requestPanelKeyboard()
            }
            .id(SessionPanelSections.groupHeaderScrollID)
            ForEach(sections.finished + (sections.pinned.map { [$0] } ?? [])) { row in
                SessionsPanelSessionRow(
                    vm: vm, projectID: project.id, row: row, actions: actions,
                    openAsks: stack.count(session: row.id), closedAsks: closed[row.id] ?? 0,
                    hoveredRow: $hoveredRow, panelHasKeyboard: hasKeyboard
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

/// What a session row's click, Rename…, Delete… and Clean Up… do; the page
/// owns the sheets and the confirmation (`sessionActionDialogs`).
struct SessionRowActions {
    let open: (TerminalSession) -> Void
    let rename: (TerminalSession) -> Void
    let delete: (TerminalSession) -> Void
    /// A workbench session's Clean Up… (board #535); nil = no menu item.
    var cleanUp: ((TerminalSession) -> Void)?
}
