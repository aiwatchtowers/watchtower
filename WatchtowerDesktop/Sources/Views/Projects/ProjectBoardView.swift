import SwiftUI
import WatchtowerCore

/// Board pane of the project page: the target tree or kanban across the
/// whole pane; the selected target's detail and comment threads open as a
/// card over it.
struct ProjectBoardView: View {
    let projectID: Int64

    @Environment(AppState.self) private var appState
    @State private var viewModel: ProjectBoardViewModel?
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
                .onExitCommand { if vm.selectedTargetID != nil { vm.select(nil) } }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if viewModel == nil, let pool = appState.databaseManager?.dbPool {
                let vm = ProjectBoardViewModel(dbPool: pool, projectID: projectID)
                vm.onOwnerWrite = { [weak projects = appState.projectsViewModel] project, subject in
                    projects?.onOwnerWrite?(project, subject)
                }
                vm.onPollTick = { [weak projects = appState.projectsViewModel, projectID] in
                    Task { await projects?.refreshDrift(projectID: projectID) }
                }
                vm.load()
                viewModel = vm
            }
            viewModel?.startPolling()
        }
        .onDisappear { viewModel?.stopPolling() }
        .task(id: projectID) {
            await appState.projectsViewModel?.refreshDrift(projectID: projectID, force: true)
        }
    }

    // MARK: - Board (list or kanban)

    private func board(_ vm: ProjectBoardViewModel) -> some View {
        let kanban = vm.mode == .kanban ? vm.kanban : nil
        return VStack(alignment: .leading, spacing: 0) {
            header(vm, kanban: kanban)
                .padding(8)
            if let projects = appState.projectsViewModel {
                ProjectDriftBanner(
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
                    description: Text("Claude Code creates the board through the watchtower-project tools.")
                )
                .frame(maxHeight: .infinity)
            } else if let kanban {
                ProjectBoardKanbanView(
                    board: kanban,
                    selectedTargetID: vm.selectedTargetID,
                    onSelect: { vm.select($0) },
                    onMove: { vm.setStatus($1, for: $0) }
                )
            } else {
                tree(vm)
            }
        }
    }

    private func header(_ vm: ProjectBoardViewModel, kanban: ProjectBoardKanban?) -> some View {
        HStack(spacing: 10) {
            Text("Board").font(.headline)
            Picker("View", selection: Binding(get: { vm.mode }, set: { vm.mode = $0 })) {
                Text("List").tag(ProjectBoardMode.list)
                Text("Kanban").tag(ProjectBoardMode.kanban)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let kanban {
                kanbanFilterMenu(vm, kanban)
            }
            Spacer()
            Toggle("Show done", isOn: Binding(get: { vm.showDone }, set: { vm.showDone = $0 }))
                .toggleStyle(.checkbox)
                .font(.caption)
        }
    }

    private func kanbanFilterMenu(_ vm: ProjectBoardViewModel, _ kanban: ProjectBoardKanban) -> some View {
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
    private func tree(_ vm: ProjectBoardViewModel) -> some View {
        if vm.rows.isEmpty {
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
                ProjectBoardCardView(
                    row: row,
                    isSelected: vm.selectedTargetID == row.id,
                    isCollapsed: vm.collapsed.contains(row.id),
                    onToggle: { vm.toggle(row.id) },
                    trailing: { hovering in
                        WorkOnTargetButton(target: row.node.target, compact: true,
                                           isVisible: hovering || vm.selectedTargetID == row.id)
                    }
                )
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                .listRowBackground(Color.clear)
            }
            .panelListStyle()
        }
    }

    // MARK: - Detail

    /// The dimmed board and the detail card over it. A click on the scrim,
    /// the card's close button or Esc clears the selection.
    private func detailOverlay(_ vm: ProjectBoardViewModel, _ node: ProjectBoardNode) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture { vm.select(nil) }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close target details")
            detail(vm, node)
                .frame(maxWidth: 620, maxHeight: .infinity)
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
                    vm.select(nil)
                    return .handled
                }
                .onAppear { cardFocused = true }
                .padding(20)
        }
    }

    private func detail(_ vm: ProjectBoardViewModel, _ node: ProjectBoardNode) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { vm.rename(titleDraft) }
                Button { vm.select(nil) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Close")
                    .accessibilityLabel("Close")
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Status and priority sit on their own row as compact
                    // menus: a segmented picker here took the whole width and
                    // squeezed the intent into a one-letter column.
                    HStack(spacing: 8) {
                        statusMenu(vm, node.target)
                        priorityMenu(vm, node.target)
                        Spacer(minLength: 0)
                        WorkOnTargetButton(target: node.target, compact: false, isVisible: true)
                    }
                    ProgressView(value: node.target.progress)
                    if !node.target.intent.isEmpty {
                        Text(node.target.intent)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !node.documents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Documents").font(.headline)
                            ForEach(node.documents, id: \.id) { doc in
                                Label(doc.title.isEmpty ? doc.relPath : doc.title, systemImage: "doc.text")
                                    .font(.callout)
                            }
                        }
                    }
                    if !vm.selectedImages.isEmpty {
                        ProjectTargetImagesSection(images: vm.selectedImages)
                    }
                    Divider()
                    Text("Comments").font(.headline)
                    ForEach(vm.threads) { thread in
                        CommentThreadView(
                            thread: thread.content,
                            onReply: { vm.reply(to: thread.id, body: $0) },
                            onResolve: thread.root.isOpen ? { vm.setThreadStatus(rootID: thread.id, status: "resolved") } : nil,
                            onReopen: thread.root.isOpen ? nil : { vm.setThreadStatus(rootID: thread.id, status: "open") }
                        )
                    }
                    HStack(alignment: .bottom) {
                        TextField("Comment or answer the agent…", text: $commentDraft, axis: .vertical)
                            .lineLimit(1...6)
                        Button("Comment") {
                            if vm.addComment(commentDraft) { commentDraft = "" }
                        }
                        .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .onAppear { titleDraft = node.target.text }
        .onChange(of: node.target.id) { titleDraft = node.target.text }
        .onChange(of: node.target.text) { titleDraft = node.target.text }
    }

    private func statusMenu(_ vm: ProjectBoardViewModel, _ target: Target) -> some View {
        Menu {
            ForEach(ProjectBoardCard.editableStatuses, id: \.self) { status in
                Toggle(ProjectBoardCard.statusLabel(status), isOn: Binding(
                    get: { target.status == status },
                    set: { if $0 { vm.setStatus(status) } }
                ))
            }
        } label: {
            ProjectBoardChip(
                text: ProjectBoardCard.statusLabel(target.status),
                color: ProjectBoardColors.status(target.statusColor)
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Status")
    }

    private func priorityMenu(_ vm: ProjectBoardViewModel, _ target: Target) -> some View {
        Menu {
            ForEach(ProjectBoardCard.editablePriorities, id: \.self) { priority in
                Toggle(priority.capitalized, isOn: Binding(
                    get: { target.priority == priority },
                    set: { if $0 { vm.setPriority(priority) } }
                ))
            }
        } label: {
            ProjectBoardChip(
                text: target.priority.capitalized,
                color: ProjectBoardColors.priority(target.priority),
                dot: true
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Priority")
    }
}
