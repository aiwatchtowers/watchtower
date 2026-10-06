import SwiftUI
import WatchtowerCore

/// Board pane of the project page: the target tree or kanban across the
/// whole pane; the selected target's detail and comment threads open as a
/// card over it.
struct WorkbenchBoardView: View {
    let projectID: Int64

    @Environment(AppState.self) private var appState
    @State private var viewModel: WorkbenchBoardViewModel?
    @State private var titleDraft = ""
    @State private var commentDraft = ""
    @FocusState private var cardFocused: Bool

    var body: some View {
        Group {
            if let vm = viewModel {
                // The board keeps the pane's full width; the selected target
                // opens as a card over it (board #155) — a side column
                // squeezed the kanban and clipped the detail at narrow
                // widths. An in-pane overlay rather than a `.sheet`: a sheet
                // is window-modal, so in a split it would cover and block the
                // terminal next to the board.
                ZStack {
                    board(vm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    if let node = vm.selectedNode {
                        detailOverlay(vm, node)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: vm.selectedTargetID == nil)
                // Esc closes the card while focus is anywhere in this pane
                // (the board list, the card's fields). Deliberately not a
                // `.keyboardShortcut(.cancelAction)`: that is window-wide and
                // would steal Esc from a Claude Code terminal in the other
                // split pane.
                .onExitCommand { if vm.selectedTargetID != nil { vm.closeDetail() } }
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
            // Board-level, not in the detail pane: a kanban drop can fail for
            // a card that is not the selected one (or with nothing selected).
            if let error = vm.errorMessage {
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
            if let kanban {
                lanesMenu(vm)
                kanbanFilterMenu(vm, kanban)
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

    private func kanbanFilterMenu(_ vm: WorkbenchBoardViewModel, _ kanban: WorkbenchBoardKanban) -> some View {
        let current = kanban.filterOptions.first { $0.id == kanban.filterRootID }
        return Menu {
            Toggle("All", isOn: Binding(
                get: { kanban.filterRootID == nil },
                set: { if $0 { vm.kanbanFilterRootID = nil } }
            ))
            if !kanban.filterOptions.isEmpty { Divider() }
            ForEach(kanban.filterOptions) { option in
                Toggle(option.title.isEmpty ? "Untitled" : option.title, isOn: Binding(
                    get: { kanban.filterRootID == option.id },
                    set: { if $0 { vm.kanbanFilterRootID = option.id } }
                ))
            }
        } label: {
            Text(current.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "All")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show only one top-level target's tasks")
    }

    // MARK: - Tree

    @ViewBuilder
    private func tree(_ vm: WorkbenchBoardViewModel) -> some View {
        if vm.rows.isEmpty, WorkbenchBoardSearch(vm.searchText) != nil {
            ContentUnavailableView.search(text: vm.searchText)
                .frame(maxHeight: .infinity)
        } else if vm.rows.isEmpty {
            ContentUnavailableView(
                "Nothing open",
                systemImage: "checkmark.circle",
                description: Text("Every target is done or dismissed. Turn on Show done to see them.")
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
                .contextMenu { WorkbenchTargetMenu(target: row.node.target, vm: vm) }
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

    // MARK: - Detail

    /// The dimmed board and the detail card over it. A click on the scrim,
    /// the card's close button or Esc closes it (`closeDetail`, which keeps
    /// an error raised from the card for the board's banner).
    private func detailOverlay(_ vm: WorkbenchBoardViewModel, _ node: WorkbenchBoardNode) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { vm.closeDetail() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close target details")
            WorkbenchTargetDetailCard(
                vm: vm,
                node: node,
                findings: appState.workbenchesViewModel?.drift[projectID]?.findings.filter { $0.targetID == node.id } ?? [],
                titleDraft: $titleDraft,
                commentDraft: $commentDraft
            ) { vm.closeDetail() }
            .frame(maxWidth: 620)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
            // The card takes keyboard focus when it opens, so Esc reaches
            // it even when a kanban click left nothing focused.
            .focusable()
            .focusEffectDisabled()
            .focused($cardFocused)
            .onKeyPress(.escape) {
                vm.closeDetail()
                return .handled
            }
            .onAppear { cardFocused = true }
            .padding(20)
        }
    }
}
