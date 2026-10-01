import AppKit
import SwiftUI
import WatchtowerCore

/// The project page's main area (spec 2026-09-30-project-workspace-sessions
/// §3): one pane, or two side by side with a draggable divider, from the
/// project's `WorkspaceLayout`. An expanded pane shows alone.
struct WorkspaceAreaView: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project

    var body: some View {
        let layout = vm.layout(projectID: project.id)
        let panes = layout.visiblePanes
        if panes.count == 2 {
            WorkspaceSplitView(fraction: layout.dividerFraction) { vm.setDividerFraction($0, projectID: project.id) } leading: {
                pane(panes[0], layout: layout)
            } trailing: {
                pane(panes[1], layout: layout)
            }
        } else if let only = panes.first {
            pane(only, layout: layout)
        }
    }

    private func pane(_ pane: WorkspacePane, layout: WorkspaceLayout) -> some View {
        WorkspacePaneView(vm: vm, project: project, pane: pane, isSplit: layout.isSplit, isExpanded: layout.expanded == pane)
    }
}

/// One pane: a slim header (the pane's own picker; in a split also expand
/// and close) over Board, Documents or a session's terminal.
struct WorkspacePaneView: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project
    let pane: WorkspacePane
    let isSplit: Bool
    let isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            picker
            Spacer(minLength: 4)
            if isSplit {
                Button {
                    vm.toggleExpand(pane, projectID: project.id)
                } label: {
                    Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Back to the split" : "Expand this pane")
                .accessibilityLabel(isExpanded ? "Back to the split" : "Expand this pane")
                if !isExpanded {
                    Button {
                        vm.closePane(pane, projectID: project.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Close this pane")
                    .accessibilityLabel("Close this pane")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var picker: some View {
        Menu {
            Button("Board") { show(.board) }.disabled(pane == .board)
            Button("Documents") { show(.documents) }.disabled(pane == .documents)
            Divider()
            Section("Sessions") {
                ForEach(vm.terminalSessions[project.id] ?? []) { session in
                    Button(session.isClosed ? "\(session.title) (closed)" : session.title) {
                        show(.session(session.id))
                    }
                    .disabled(pane == .session(session.id))
                }
                Button("New session") {
                    Task { await vm.newSession(inPane: pane, projectID: project.id) }
                }
            }
        } label: {
            Label(title, systemImage: icon).font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show something else in this pane")
    }

    private func show(_ item: WorkspacePane) {
        Task { await vm.showInPane(pane, item: item, projectID: project.id) }
    }

    private var title: String {
        switch pane {
        case .board: "Board"
        case .documents: "Documents"
        case let .session(id): vm.session(id, projectID: project.id)?.title ?? "Session"
        }
    }

    private var icon: String {
        switch pane {
        case .board: "square.grid.2x2"
        case .documents: "doc.text"
        case .session: "terminal"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch pane {
        case .board:
            ProjectBoardView(projectID: project.id)
                .id(project.id)
        case .documents:
            ProjectDocumentsView(vm: vm)
        case let .session(id):
            ProjectSessionView(projectID: project.id, sessionID: id)
                .id(id)
        }
    }
}

/// Two panes side by side. The divider follows the drag live and reports
/// its fraction once, when the drag ends (the layout persists it).
struct WorkspaceSplitView<Leading: View, Trailing: View>: View {
    static var handleWidth: CGFloat { 7 }

    let fraction: Double
    let onCommit: (Double) -> Void
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let current = dragFraction ?? fraction
            HStack(spacing: 0) {
                leading().frame(width: max(0, (width - Self.handleWidth) * current))
                divider(width: width)
                trailing().frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: Self.space)
        }
    }

    private static var space: String { "workspace-split" }

    private func divider(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(width: Self.handleWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        guard width > 0 else { return }
                        let range = WorkspaceLayout.dividerRange
                        dragFraction = min(max(Double(value.location.x / width), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        if let dragFraction { onCommit(dragFraction) }
                        dragFraction = nil
                    }
            )
            .accessibilityHidden(true)
    }
}
