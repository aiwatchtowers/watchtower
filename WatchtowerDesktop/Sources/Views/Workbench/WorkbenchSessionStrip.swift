import SwiftUI
import WatchtowerCore

/// The slim bar on top of every pane of a session — its terminal, Workchat,
/// report or Changes (spec 2026-10-20-workbench-header §2): `session ▾`,
/// the place and branch crumbs, `[Terminal | Workchat]`, Report, Changes,
/// and in a split expand and close. Each strip acts on its own pane and
/// session (call 8); the crumbs show only on the strip whose session sets
/// the page's code root (call 9); no pane picker (call 10).
struct WorkbenchSessionStrip: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let pane: WorkspacePane
    let sessionID: Int64
    let isSplit: Bool
    let isExpanded: Bool
    @State private var hovered: String?

    var body: some View {
        HStack(spacing: Spacing.regular) {
            WorkbenchSessionsMenu(vm: vm, project: project, slot: pane, title: title)
            if vm.ownsCodeRoot(sessionID: sessionID, projectID: project.id) {
                WorkbenchPlaceCrumb(vm: vm, project: project)
                WorkbenchBranchCrumb(vm: vm, project: project)
            }
            Spacer(minLength: Spacing.small)
            HStack(spacing: Spacing.tight) {
                modeToggle("Terminal", pane: .session(sessionID))
                modeToggle("Workchat", pane: .sessionChat(sessionID))
            }
            .segmentCapsule()
            viewToggle("Report", view: .report)
            viewToggle("Changes", view: .changes)
            if isSplit { paneButtons }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.tight)
    }

    private var title: String {
        vm.session(sessionID, projectID: project.id)?.title ?? "Session"
    }

    /// One half of `[Terminal | Workchat]`, for this strip's session:
    /// lit when this pane shows that mode. Turning the other half on swaps
    /// this pane in place — the other pane of a split stays; over the
    /// session's report or Changes this pane shows the session in that
    /// mode. A mode already on screen in the other pane is disabled, not a
    /// click that does nothing; the lit half stays lit — the capsule picks
    /// a mode, it never empties the pane.
    private func modeToggle(_ label: String, pane mode: WorkspacePane) -> some View {
        let view: WorkspaceView = mode.isWorkchat ? .chat : .terminal
        let shownElsewhere = pane != mode && vm.layout(projectID: project.id).visiblePanes.contains(mode)
        return Toggle(isOn: Binding(
            get: { pane == mode },
            set: { on in
                guard on else { return }
                if WorkspaceLayout.sessionID(of: pane) == sessionID {
                    vm.toggleMode(sessionID: sessionID, projectID: project.id)
                } else {
                    Task {
                        await vm.showSession(sessionID, workchat: mode.isWorkchat, inPane: pane, projectID: project.id)
                    }
                }
            }
        )) {
            Label(label, systemImage: view.icon)
        }
        .toggleStyle(segmentStyle(label))
        .help(mode.isWorkchat ? "Show this session's Workchat in this pane (⌃`)" : "Show this session's terminal in this pane (⌃`)")
        .disabled(shownElsewhere)
    }

    /// Report or Changes of this strip's session: lit while it is on
    /// screen; on puts it beside its session's terminal (a single pane
    /// splits), off closes it in a split — a single pane is never removed.
    private func viewToggle(_ label: String, view: WorkspaceView) -> some View {
        let target: WorkspacePane = view == .report ? .sessionReport(sessionID) : .changes(sessionID)
        let visible = vm.layout(projectID: project.id).visiblePanes
        return Toggle(isOn: Binding(
            get: { visible.contains(target) },
            set: { on in
                if on {
                    vm.showBesideItsSession(target, sessionID: sessionID, projectID: project.id)
                } else if visible.count == 2 {
                    vm.closePane(target, projectID: project.id)
                }
            }
        )) {
            Label(label, systemImage: view.icon)
        }
        .toggleStyle(segmentStyle(label))
        .segmentCapsule()
        .help(view == .report ? "Show this session's report beside its terminal" : "Review this session's changes")
    }

    private func segmentStyle(_ label: String) -> SegmentedToggleStyle {
        SegmentedToggleStyle(showsIcon: false, isHovered: hovered == label) { inside in
            if inside { hovered = label } else if hovered == label { hovered = nil }
        }
    }

    /// The split pane's expand and close, as the old split-pane header had them.
    @ViewBuilder private var paneButtons: some View {
        Button {
            vm.toggleExpand(pane, projectID: project.id)
        } label: {
            Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.kitIcon(isOn: isExpanded))
        .help(isExpanded ? "Back to the split" : "Expand this pane")
        .accessibilityLabel(isExpanded ? "Back to the split" : "Expand this pane")
        if !isExpanded {
            Button {
                vm.closePane(pane, projectID: project.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.kitIcon(isOn: false))
            .help("Close this pane")
            .accessibilityLabel("Close this pane")
        }
    }
}

/// `session ▾`: which session a pane shows — in the mode it was last shown
/// in — or a new one there. The session strip's menu; its items are the
/// page header's twin chevron's too.
struct WorkbenchSessionsMenu: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let slot: WorkspacePane
    let title: String

    var body: some View {
        Menu {
            // The pane's own session, whatever it shows of it, is the one ticked off.
            WorkbenchSessionMenuItems(vm: vm, project: project, slot: slot, current: WorkspaceLayout.sessionID(ofAny: slot))
        } label: {
            HStack(spacing: Spacing.small) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help("Show another session in this pane, or start a new one")
        .accessibilityLabel("Sessions")
    }
}

/// The sessions menus' items: every session of the workbench but
/// `current` (disabled), opened in `slot` (resumed if not running), then
/// the New Session items.
struct WorkbenchSessionMenuItems: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let slot: WorkspacePane
    let current: Int64?

    var body: some View {
        ForEach(vm.orderedSessions(projectID: project.id)) { session in
            Button(session.title) {
                Task { await vm.showInPane(slot, item: .session(session.id), projectID: project.id) }
            }
            .disabled(current == session.id)
        }
        Divider()
        NewSessionMenuItems(vm: vm, projectID: project.id) { agent, worktree in
            Task { await vm.newSession(inPane: slot, projectID: project.id, agent: agent, worktree: worktree) }
        }
    }
}
