import SwiftUI
import WatchtowerCore

/// Board pane of the project page: the target tree or kanban across the
/// whole pane; the open target shows in a side panel over its trailing edge
/// (spec 2026-10-06 Part 3).
struct WorkbenchBoardView: View {
    let projectID: Int64

    /// The side panel's width: dragged within `panelWidthRange`, remembered
    /// for every workbench.
    static let panelDefaultWidth: Double = 460
    static let panelWidthRange: ClosedRange<Double> = 360...720

    @Environment(AppState.self) private var appState
    @State private var viewModel: WorkbenchBoardViewModel?
    @State private var titleDraft = ""
    @AppStorage("projects.boardPanelWidth") private var panelWidth = Self.panelDefaultWidth
    @State private var dragPanelWidth: Double?
    @FocusState private var panelFocused: Bool
    /// The path bar takes focus when the panel closes inside a scope, or a
    /// scope is entered, so the next Esc leaves one level even in Kanban,
    /// where a card click focuses nothing.
    @FocusState private var pathBarFocused: Bool

    var body: some View {
        Group {
            if let vm = viewModel {
                // The board keeps the pane's full width; the open target's
                // panel lies over its trailing edge with no scrim (owner
                // ruling 2026-10-06), so another card stays one click away
                // and swaps the panel. In-pane rather than a `.sheet` or an
                // `.inspector`: both act on the window, and in a split they
                // would cover or squeeze the terminal next to the board.
                ZStack(alignment: .trailing) {
                    board(vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if let node = vm.selectedNode {
                        panel(vm, node)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: vm.selectedTargetID == nil)
                // Esc while focus is anywhere in this pane (the board list,
                // the panel's fields): the panel closes first; only with it
                // closed does Esc leave one scope level (spec 2026-10-06
                // Part 4). Deliberately not a `.keyboardShortcut(.cancelAction)`:
                // that is window-wide and would steal Esc from a Claude Code
                // terminal in the other split pane.
                .onExitCommand { _ = escape(vm) }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if viewModel == nil, let pool = appState.databaseManager?.dbPool {
                let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: projectID)
                vm.onOwnerWrite = { [weak projects = appState.workbenchesViewModel] project, subject in
                    projects?.onOwnerWrite?(project, subject)
                }
                vm.onPollTick = { [weak projects = appState.workbenchesViewModel, projectID] in
                    Task { await projects?.refreshDrift(projectID: projectID) }
                }
                vm.load()
                viewModel = vm
            }
            takeFocus()
            viewModel?.startPolling()
        }
        // A target id in the Session view opens its card here.
        .onChange(of: appState.workbenchesViewModel?.boardFocus[projectID]) { _, _ in takeFocus() }
        .onDisappear { viewModel?.stopPolling() }
        // The header's "Archive Closed Targets After" applies at once, not at
        // the next poll (board #301); load() reports a failed read.
        .onChange(of: archiveAfterDays) { _, _ in viewModel?.load() }
        .task(id: projectID) {
            await appState.workbenchesViewModel?.refreshDrift(projectID: projectID, force: true)
        }
    }

    private var archiveAfterDays: Int? {
        appState.workbenchesViewModel?.summaries.first { $0.id == projectID }?.project.archiveAfterDays
    }

    /// One Esc from the panel, the path bar or the board: the rule is the
    /// view model's (`escape()`); a panel it closed inside a scope hands
    /// focus to the path bar, so the next Esc leaves the group.
    private func escape(_ vm: WorkbenchBoardViewModel) -> KeyPress.Result {
        let closesPanel = vm.selectedTargetID != nil
        guard vm.escape() else { return .ignored }
        if closesPanel, vm.scopeNode != nil { pathBarFocused = true }
        return .handled
    }

    /// The panel's ✕. Inside a scope the path bar takes focus, so the next
    /// Esc leaves the group.
    private func closePanel(_ vm: WorkbenchBoardViewModel) {
        vm.closeDetail()
        if vm.scopeNode != nil { pathBarFocused = true }
    }

    /// Open Group from the list or the panel, or a lane header
    /// double-click (`enter`, `WorkbenchBoardViewModel.enterLane` there).
    /// With the panel closed the path bar takes focus — on the next turn, as
    /// entering from the board root is what puts the bar on screen.
    private func enterScopeAndFocus(
        _ vm: WorkbenchBoardViewModel,
        _ id: Int,
        enter: (Int) -> Bool
    ) {
        guard enter(id), vm.selectedTargetID == nil, vm.scopeNode != nil else { return }
        DispatchQueue.main.async { pathBarFocused = true }
    }

    private func takeFocus() {
        guard let vm = viewModel, let id = appState.workbenchesViewModel?.takeBoardFocus(projectID: projectID) else { return }
        vm.select(Int(id))
    }

    // MARK: - Board (list or kanban)

    private func board(_ vm: WorkbenchBoardViewModel) -> some View {
        let kanban = vm.mode == .kanban ? vm.kanban : nil
        return VStack(alignment: .leading, spacing: 0) {
            header(vm, kanban: kanban)
                .padding(8)
            if !vm.scopePath.isEmpty {
                WorkbenchBoardPathBar(
                    path: vm.scopePath,
                    showArchived: vm.showArchived,
                    onJump: { vm.enterScope($0) },
                    onLeave: { vm.leaveScope() }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .focusable()
                .focusEffectDisabled()
                .focused($pathBarFocused)
                // The same rule as everywhere in the pane: the panel first.
                .onKeyPress(.escape) { escape(vm) }
            }
            if let projects = appState.workbenchesViewModel {
                WorkbenchDriftBanner(
                    report: projects.drift[projectID],
                    error: projects.driftErrors[projectID],
                    onSelect: { vm.select($0) },
                    onRefresh: { Task { await projects.refreshDrift(projectID: projectID, force: true) } }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            // Board-level: a kanban drop can fail for a card that is not the
            // open one (or with nothing open). While the panel is open the
            // same message shows in its error row instead, not twice.
            if let error = vm.boardBannerError {
                HStack(alignment: .top) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button { vm.dismissError() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }
            Divider()
            if vm.roots.isEmpty {
                ContentUnavailableView(
                    "No targets yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Claude Code creates the board through the watchtower-workbench tools.")
                )
                .frame(maxHeight: .infinity)
            } else if let kanban {
                WorkbenchBoardKanbanView(
                    board: kanban,
                    vm: vm,
                    selectedTargetID: vm.selectedTargetID,
                    onSelect: { vm.select($0) },
                    onEnter: { enterScopeAndFocus(vm, $0, enter: { vm.enterLane($0) }) },
                    onMove: { vm.setStatus($1, for: $0) }
                )
            } else {
                tree(vm)
            }
        }
    }

    private func header(_ vm: WorkbenchBoardViewModel, kanban: WorkbenchBoardKanban?) -> some View {
        HStack(spacing: 10) {
            Text("Board").font(.headline)
            Picker("View", selection: Binding(get: { vm.mode }, set: { vm.mode = $0 })) {
                Text("List").tag(WorkbenchBoardMode.list)
                Text("Kanban").tag(WorkbenchBoardMode.kanban)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if kanban != nil {
                lanesMenu(vm)
            }
            Spacer()
            searchField(vm)
            Toggle("Show done", isOn: Binding(get: { vm.showDone }, set: { vm.showDone = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
            Toggle("Archive (\(vm.archivedCount))", isOn: Binding(get: { vm.showArchived }, set: { vm.showArchived = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Show the targets closed longer than the workbench's archive setting (… menu). Reopen one to bring it back.")
        }
    }

    /// Title, intent or number (`#163` / `163`); a search also finds done
    /// and dismissed targets.
    private func searchField(_ vm: WorkbenchBoardViewModel) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search or #id", text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }))
                .textFieldStyle(.plain)
                .onExitCommand { vm.searchText = "" }
            if !vm.searchText.isEmpty {
                Button { vm.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear the search")
            }
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: 200)
        .help("Search the board by title, intent or #number")
    }

    /// "Lanes: By group | None" (spec 2026-10-06 Part 2), remembered per
    /// workbench.
    private func lanesMenu(_ vm: WorkbenchBoardViewModel) -> some View {
        Picker("Lanes", selection: Binding(get: { vm.lanesMode }, set: { vm.lanesMode = $0 })) {
            Text("By group").tag(WorkbenchBoardLanesMode.group)
            Text("None").tag(WorkbenchBoardLanesMode.none)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("One lane per top-level group, or the flat columns")
    }

    // MARK: - Tree

    @ViewBuilder
    private func tree(_ vm: WorkbenchBoardViewModel) -> some View {
        if vm.rows.isEmpty, WorkbenchBoardSearch(vm.searchText) != nil {
            ContentUnavailableView.search(text: vm.searchText)
                .frame(maxHeight: .infinity)
        } else if vm.rows.isEmpty {
            ContentUnavailableView(
                vm.showDone ? "Nothing to show" : "Nothing open",
                systemImage: "checkmark.circle",
                description: Text(vm.emptyBoardText)
            )
            .frame(maxHeight: .infinity)
        } else {
            // List selection keeps arrow-key navigation; the card draws the
            // selected look itself, keyed off the selection, over a clear
            // row background.
            List(vm.rows, selection: Binding(get: { vm.selectedTargetID }, set: { vm.select($0) })) { row in
                WorkbenchBoardCardView(
                    row: row,
                    isSelected: vm.selectedTargetID == row.id,
                    isCollapsed: vm.collapsed.contains(row.id),
                    onToggle: { vm.toggle(row.id) },
                    trailing: { hovering in
                        WorkOnTargetButton(target: row.node.target, compact: true,
                                           isVisible: hovering || vm.selectedTargetID == row.id)
                    }
                )
                .contextMenu {
                    WorkbenchTargetMenu(target: row.node.target, vm: vm) {
                        enterScopeAndFocus(vm, $0, enter: { vm.enterScope($0) })
                    }
                }
                // Drop a row onto another to nest it there (board #186).
                .draggable(WorkbenchTargetDrag.payload(row.id))
                .dropDestination(for: String.self) { items, _ in
                    let moved = items.compactMap(WorkbenchTargetDrag.targetID).filter { vm.move($0, under: row.id) }
                    return !moved.isEmpty
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                .listRowBackground(Color.clear)
            }
            .workspaceListStyle()
        }
    }

    // MARK: - Panel

    /// The side panel with its resize strip on the leading edge. The panel's
    /// close button or Esc closes it (`closeDetail`, which keeps an error
    /// raised from the panel for the board's banner).
    private func panel(_ vm: WorkbenchBoardViewModel, _ node: WorkbenchBoardNode) -> some View {
        WorkbenchTargetPanel(
            vm: vm,
            node: node,
            findings: appState.workbenchesViewModel?.drift[projectID]?.findings.filter { $0.targetID == node.id } ?? [],
            titleDraft: $titleDraft,
            onShowAsk: { [weak projects = appState.workbenchesViewModel] askID, projectID in
                await projects?.showAsk(askID, projectID: projectID) ?? false
            },
            askOpenFailure: { [weak projects = appState.workbenchesViewModel, projectID] in
                guard let projects else { return "the workbench list is not loaded." }
                return projects.asks.loadErrors[projectID]
            },
            onOpenGroup: { enterScopeAndFocus(vm, $0, enter: { vm.enterScope($0) }) },
            onClose: { closePanel(vm) }
        )
        .frame(maxWidth: dragPanelWidth ?? clampedPanelWidth, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
        // Flattened first, so the shadow is the panel's outline and not a
        // blurred halo behind each line of text.
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 12, x: -2)
        .overlay(alignment: .leading) {
            PanelResizeHandle(
                width: $panelWidth,
                liveWidth: $dragPanelWidth,
                range: Self.panelWidthRange,
                growsLeftward: true
            )
        }
        // The panel takes keyboard focus when it opens, so Esc reaches it
        // even when a kanban click left nothing focused.
        .focusable()
        .focusEffectDisabled()
        .focused($panelFocused)
        .onKeyPress(.escape) { escape(vm) }
        .onAppear { panelFocused = true }
        // Transparent, never hit-tested: a narrow pane keeps a strip of the
        // board clickable beside the panel.
        .padding(.leading, 40)
    }

    private var clampedPanelWidth: Double {
        min(max(panelWidth, Self.panelWidthRange.lowerBound), Self.panelWidthRange.upperBound)
    }
}
