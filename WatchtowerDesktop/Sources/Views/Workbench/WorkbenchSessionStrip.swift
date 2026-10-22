import SwiftUI
import WatchtowerCore

/// The slim bar on top of every pane of a session — its terminal, Workchat,
/// report or Branch review (spec 2026-10-20-workbench-header §2): `session ▾`,
/// the place and branch crumbs, one Terminal/Workchat button, Report, Review,
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
            WorkbenchSessionsMenu(vm: vm, project: project, slot: pane)
            if vm.crumbsPane(projectID: project.id) == pane {
                WorkbenchPlaceCrumb(vm: vm, project: project)
                WorkbenchBranchCrumb(vm: vm, project: project)
            }
            Spacer(minLength: Spacing.small)
            modeButton()
                // The button never truncates; the session name and the crumbs do.
                .fixedSize()
                .layoutPriority(1)
            viewToggle("Report", view: .report)
            // Review only while this session has something to review or its
            // Branch review pane is on screen (board #712, spec §5).
            if vm.showsReviewButton(sessionID: sessionID, projectID: project.id) {
                viewToggle(WorkspaceView.changes.reviewButtonTitle, view: .changes)
            }
            if isSplit {
                WorkspacePaneButtons(vm: vm, project: project, pane: pane, isExpanded: isExpanded)
            }
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.tight)
    }

    /// What the mode button of a pane shows for a session: the mode it
    /// switches to and that mode's pane. A terminal names Workchat, a
    /// Workchat names Terminal; over the session's report or Branch review it
    /// names the session's remembered mode.
    static func modeButton(pane: WorkspacePane, sessionID: Int64, layout: WorkspaceLayout) -> (label: String, target: WorkspacePane) {
        let target: WorkspacePane
        switch pane {
        case .session(let id) where id == sessionID: target = .sessionChat(sessionID)
        case .sessionChat(let id) where id == sessionID: target = .session(sessionID)
        default: target = layout.pane(forSession: sessionID)
        }
        return (target.isWorkchat ? "Workchat" : "Terminal", target)
    }

    /// One button for this strip's session that names the mode it switches
    /// to. On the session's own pane it swaps this pane in place (the other
    /// pane of a split stays); over its report or Branch review this pane
    /// shows the session in the remembered mode. A mode already on screen in
    /// the other pane is disabled, not a click that does nothing. It is never
    /// lit: it is an action, not a state.
    private func modeButton() -> some View {
        let layout = vm.layout(projectID: project.id)
        let (label, target) = Self.modeButton(pane: pane, sessionID: sessionID, layout: layout)
        let view: WorkspaceView = target.isWorkchat ? .chat : .terminal
        let shownElsewhere = pane != target && layout.visiblePanes.contains(target)
        return Toggle(isOn: Binding(
            get: { false },
            set: { _ in
                if WorkspaceLayout.sessionID(of: pane) == sessionID {
                    vm.toggleMode(sessionID: sessionID, projectID: project.id)
                } else {
                    Task {
                        await vm.showSession(sessionID, workchat: target.isWorkchat, inPane: pane, projectID: project.id)
                    }
                }
            }
        )) {
            Label(label, systemImage: view.icon)
        }
        .toggleStyle(segmentStyle(label))
        .segmentCapsule()
        .help("Show this session's \(target.isWorkchat ? "Workchat" : "terminal") in this pane (⌃`)")
        .disabled(shownElsewhere)
    }

    /// Report or Review (its Branch review pane) of this strip's session: lit while it is on
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
        .help(view == .report ? "Show this session's report beside its terminal" : WorkspaceView.changes.help)
    }

    private func segmentStyle(_ label: String) -> SegmentedToggleStyle {
        SegmentedToggleStyle(showsIcon: false, isHovered: hovered == label) { inside in
            if inside { hovered = label } else if hovered == label { hovered = nil }
        }
    }
}

/// `● session ▾`: which session a pane shows — in the mode it was last
/// shown in — or a new one there. The session strip's menu, the only session
/// switcher on the page (spec 2026-10-20 call 5); its label carries the
/// session's live dot and state, as the title row's switcher did. The
/// sessions are listed in the panel's order (PROJ-11(b)): the main list,
/// then every finished one, folded in the panel or not — as Go to… lists them.
struct WorkbenchSessionsMenu: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let slot: WorkspacePane

    var body: some View {
        // The pane's own session, whatever it shows of it: named and ticked off.
        let current = WorkspaceLayout.sessionID(ofAny: slot)
        let session = current.flatMap { vm.session($0, projectID: project.id) }
        Menu {
            ForEach(vm.panelOrderedSessions(projectID: project.id)) { row in
                Button(row.title) {
                    Task { await vm.showInPane(slot, item: .session(row.id), projectID: project.id) }
                }
                .disabled(current == row.id)
            }
            Divider()
            NewSessionMenuItems(vm: vm, projectID: project.id) { agent, worktree in
                Task { await vm.newSession(inPane: slot, projectID: project.id, agent: agent, worktree: worktree) }
            }
        } label: {
            HStack(spacing: Spacing.small) {
                if let session {
                    SessionLiveDot(state: vm.sessionState(session))
                }
                Text(session?.title ?? "Session").lineLimit(1).truncationMode(.middle)
                if let session {
                    SessionStateLabel(state: vm.sessionState(session))
                        .layoutPriority(-1)
                }
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
