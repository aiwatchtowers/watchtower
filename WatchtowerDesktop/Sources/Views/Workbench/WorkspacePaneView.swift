import AppKit
import SwiftUI
import WatchtowerCore

/// The project page's main area (spec 2026-09-30-project-workspace-sessions
/// §3): one pane, or two side by side with a draggable divider, from the
/// project's `WorkspaceLayout`. Both slots of a split stay in the view tree
/// while one is expanded (the other at zero width), so expanding and
/// collapsing back keeps each pane's own state — a comment draft, the
/// board's selection.
struct WorkspaceAreaView: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench

    var body: some View {
        let layout = vm.layout(projectID: project.id)
        let slots = [layout.primary] + (layout.secondary.map { [$0] } ?? [])
        WorkspaceSplitView(
            panes: slots, expanded: layout.expanded, fraction: layout.dividerFraction,
            onCommit: { vm.setDividerFraction($0, projectID: project.id) },
            pane: { pane in
                WorkspacePaneView(
                    vm: vm, project: project, pane: pane, isSplit: layout.isSplit,
                    isExpanded: layout.expanded == pane, isHidden: layout.expanded.map { $0 != pane } ?? false
                )
            }
        )
    }
}

/// One pane: Board, Files, Analytics, or a session's terminal, Workchat,
/// report or Branch review. A session's pane always has its session strip
/// (`WorkbenchSessionStrip`, spec 2026-10-20 §2); any other pane has a strip
/// of the same look in a split only (its own picker, expand and close, §3)
/// — a single one has none, the title row's lit tab or Analytics icon says
/// what it is.
struct WorkspacePaneView: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let pane: WorkspacePane
    let isSplit: Bool
    let isExpanded: Bool
    /// The other pane of an expanded split: kept for its state, not shown.
    /// A hidden terminal is detached (the center keeps its process) rather
    /// than squeezed to zero columns.
    let isHidden: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let sessionID = WorkspaceLayout.sessionID(ofAny: pane) {
                WorkbenchSessionStrip(
                    vm: vm, project: project, pane: pane, sessionID: sessionID, isSplit: isSplit, isExpanded: isExpanded
                )
                Divider()
            } else if isSplit {
                header
                Divider()
            }
            if isHidden, [.terminal, .report, .changes, .analytics, .chat].contains(WorkspaceView(pane)) {
                // A hidden Session view leaves the screen too: its report
                // stops refreshing until it is back; so do a Changes pane
                // and the Analytics pane.
                Color.clear
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Shown only in a split, on a pane that is not a session's (`body`):
    /// its picker, expand and close, at the session strip's height and look
    /// (spec 2026-10-20 §3) — same fonts, control size, paddings and icon
    /// buttons.
    private var header: some View {
        HStack(spacing: Spacing.regular) {
            picker
            Spacer(minLength: Spacing.small)
            WorkspacePaneButtons(vm: vm, project: project, pane: pane, isExpanded: isExpanded)
        }
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.tight)
    }

    private var picker: some View {
        Menu {
            Button("Board") { show(.board) }.disabled(pane == .board)
            Button("Files") { show(.files) }.disabled(pane == .files)
            Button("Analytics") { show(.analytics) }.disabled(pane == .analytics)
            if let id = currentSessionID {
                Button("Branch review") { show(.changes(id)) }.disabled(pane == .changes(id))
                Button("Workchat") { show(.sessionChat(id)) }.disabled(pane == .sessionChat(id))
            }
            Divider()
            Section("Sessions") {
                ForEach(vm.orderedSessions(projectID: project.id)) { session in
                    Button(session.title) {
                        show(.session(session.id))
                    }
                    .disabled(pane == .session(session.id))
                }
                NewSessionMenuItems(vm: vm, projectID: project.id) { agent, worktree in
                    Task { await vm.newSession(inPane: pane, projectID: project.id, agent: agent, worktree: worktree) }
                }
            }
        } label: {
            // The session strip's `session ▾` look.
            HStack(spacing: Spacing.small) {
                Label(title, systemImage: icon).lineLimit(1)
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show something else in this pane")
    }

    /// The session the pane picker's Branch review reviews: the one in a slot (in
    /// its terminal or its Workchat), else the active one.
    private var currentSessionID: Int64? {
        vm.layout(projectID: project.id).shownSessionIDs.first ?? vm.activeSessionID(projectID: project.id)
    }

    private func show(_ item: WorkspacePane) {
        Task { await vm.showInPane(pane, item: item, projectID: project.id) }
    }

    private var title: String {
        if case let .session(id) = pane { return vm.session(id, projectID: project.id)?.title ?? "Session" }
        return WorkspaceView(pane).title
    }

    private var icon: String { WorkspaceView(pane).icon }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .board:
            WorkbenchBoardView(projectID: project.id)
                .id(project.id)
        case let .session(id):
            WorkbenchSessionView(projectID: project.id, sessionID: id)
                .id(id)
        case .files:
            CodeFilesPaneView(files: vm.codeFiles, project: project, root: vm.activeCodeRoot(project: project))
                .id(project.id)
        case .analytics:
            AgentAnalyticsPaneView(vm: vm, project: project)
                .id(project.id)
        case let .sessionReport(id):
            WorkbenchSessionReportView(vm: vm, project: project, sessionID: id)
                .id(id)
        case let .sessionChat(id):
            WorkchatAskDrawerHost(vm: vm, projectID: project.id, sessionID: id) {
                SessionChatView(vm: vm, sessionID: id, projectID: project.id)
            }
            .id(id)
        case let .changes(id):
            if let model = vm.reviewModel(sessionID: id, projectID: project.id) {
                ReviewChangesPaneView(
                    model: model,
                    identity: reviewIdentity(sessionID: id),
                    agentStateKind: vm.session(id, projectID: project.id).map { vm.sessionState($0).kind },
                    lessons: vm.reviewLessonsModel(projectID: project.id)
                )
                .id(id)
            } else {
                Text(WorkbenchesViewModel.cliMissingMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension WorkspacePaneView {
    /// The Branch review's identity bar inputs (#712): the session's row,
    /// where its agent works and the main folder's status; the title opens
    /// the session in its recorded mode, the ⋯ menu's Open in Terminal its terminal.
    func reviewIdentity(sessionID id: Int64) -> ReviewSessionIdentity {
        let session = vm.session(id, projectID: project.id)
        let projectID = project.id
        return ReviewSessionIdentity(
            row: session.flatMap { vm.sessionRows([$0]).first },
            place: vm.sessionPlaces.currentPlace(sessionID: id),
            stale: vm.sessionPlaces.isPlaceStale(sessionID: id),
            mainStatus: vm.gitStatus[projectID],
            agentName: session?.kind.agent?.displayName ?? "Agent",
            openSession: { [vm] in Task { await vm.showSession(id: id) } },
            openTerminal: { [vm] in Task { await vm.showTerminal(sessionID: id, projectID: projectID) } }
        )
    }
}

/// One or two panes side by side, each keyed by its pane so a pane keeps
/// its identity (and state) as the layout changes. The divider follows the
/// drag live and reports its fraction once, when the drag ends (the layout
/// persists it). With `expanded` set, that pane takes the whole width.
struct WorkspaceSplitView<Pane: View>: View {
    private static var handleWidth: CGFloat { 7 }
    private static var space: String { "workspace-split" }

    let panes: [WorkspacePane]
    let expanded: WorkspacePane?
    let fraction: Double
    let onCommit: (Double) -> Void
    @ViewBuilder let pane: (WorkspacePane) -> Pane
    @State private var dragFraction: Double?
    @State private var cursorPushed = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element) { index, item in
                    if index == 1 && expanded == nil { divider(width: width) }
                    pane(item)
                        .frame(width: paneWidth(index: index, item: item, total: width))
                        // Zero width does not clip: without this its header
                        // would draw over the expanded pane's controls.
                        .clipped()
                        .opacity(isHidden(item) ? 0 : 1)
                        .disabled(isHidden(item))
                        .allowsHitTesting(!isHidden(item))
                        .accessibilityHidden(isHidden(item))
                }
            }
            .coordinateSpace(name: Self.space)
        }
        .onDisappear { popCursor() }
    }

    private func isHidden(_ item: WorkspacePane) -> Bool {
        expanded.map { $0 != item } ?? false
    }

    private func paneWidth(index: Int, item: WorkspacePane, total: CGFloat) -> CGFloat {
        if let expanded { return expanded == item ? total : 0 }
        guard panes.count == 2 else { return total }
        let content = max(0, total - Self.handleWidth)
        let leading = content * (dragFraction ?? fraction)
        return index == 0 ? leading : content - leading
    }

    private func divider(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: Self.handleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, !cursorPushed {
                    NSCursor.resizeLeftRight.push()
                    cursorPushed = true
                } else if !inside {
                    popCursor()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let content = width - Self.handleWidth
                        guard content > 0 else { return }
                        let range = WorkspaceLayout.dividerRange
                        let raw = Double((value.location.x - Self.handleWidth / 2) / content)
                        dragFraction = min(max(raw, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        if let dragFraction { onCommit(dragFraction) }
                        dragFraction = nil
                    }
            )
            .onDisappear { popCursor() }
            .accessibilityHidden(true)
    }

    /// Balanced with the hover push: a divider that disappears under the
    /// pointer (expand, unsplit) must not leave the resize cursor stuck.
    private func popCursor() {
        guard cursorPushed else { return }
        NSCursor.pop()
        cursorPushed = false
    }
}

/// The names and symbols of what a pane shows — the page header's view
/// buttons and the split panes' pickers.
extension WorkspaceView {
    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .report: "Session"
        case .board: "Board"
        case .files: "Files"
        case .analytics: "Analytics"
        case .changes: "Branch review"
        case .chat: "Workchat"
        }
    }

    var icon: String {
        switch self {
        case .terminal: "terminal"
        case .report: "list.bullet.rectangle"
        case .board: "square.grid.2x2"
        case .files: "chevron.left.forwardslash.chevron.right"
        case .analytics: "chart.bar.xaxis"
        case .changes: "plus.forwardslash.minus"
        case .chat: "bubble.left.and.bubble.right"
        }
    }
}

/// A split pane's expand and close, on its strip — the session strip's and
/// the Board, Files and Analytics panes' alike. Expanded, only the way back.
struct WorkspacePaneButtons: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let pane: WorkspacePane
    let isExpanded: Bool

    var body: some View {
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
