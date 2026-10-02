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

/// One pane: Board, Documents or a session's terminal. In a split it has a
/// slim header (its own picker, expand and close); a single pane has none —
/// the page header's view buttons and the panel's session list cover it, so
/// the terminal gets the height.
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
            if isSplit {
                header
                Divider()
            }
            if isHidden, case .session = pane {
                Color.clear
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Shown only in a split (`body`).
    private var header: some View {
        HStack(spacing: 6) {
            picker
            Spacer(minLength: 4)
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
        .font(.caption)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var picker: some View {
        Menu {
            Button("Board") { show(.board) }.disabled(pane == .board)
            Button("Documents") { show(.documents) }.disabled(pane == .documents)
            Button("Files") { show(.files) }.disabled(pane == .files)
            Divider()
            Section("Sessions") {
                ForEach(vm.orderedSessions(projectID: project.id)) { session in
                    Button(session.title) {
                        show(.session(session.id))
                    }
                    .disabled(pane == .session(session.id))
                }
                Button("New session") {
                    Task { await vm.newSession(inPane: pane, projectID: project.id) }
                }
            }
        } label: {
            Label(title, systemImage: icon).font(.subheadline)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show something else in this pane")
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
        case .documents:
            WorkbenchDocumentsView(vm: vm)
        case let .session(id):
            WorkbenchSessionView(projectID: project.id, sessionID: id)
                .id(id)
        case .files:
            CodeFilesPaneView(files: vm.codeFiles, project: project)
                .id(project.id)
        }
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
        case .board: "Board"
        case .documents: "Documents"
        case .files: "Files"
        }
    }

    var icon: String {
        switch self {
        case .terminal: "terminal"
        case .board: "square.grid.2x2"
        case .documents: "doc.text"
        case .files: "chevron.left.forwardslash.chevron.right"
        }
    }
}
