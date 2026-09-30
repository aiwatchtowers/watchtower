import SwiftUI
import WatchtowerCore

/// Board pane of the project page: tree on the left, the selected target's
/// detail and comment threads on the right.
struct ProjectBoardView: View {
    let projectID: Int64

    @Environment(AppState.self) private var appState
    @State private var viewModel: ProjectBoardViewModel?
    @State private var titleDraft = ""
    @State private var commentDraft = ""

    var body: some View {
        Group {
            if let vm = viewModel {
                // Both columns fill the height: an HSplitView pane sized to its
                // content floats (the tree sank to the bottom under empty
                // space and the "Select a target" placeholder was clipped).
                HSplitView {
                    tree(vm)
                        .frame(minWidth: 260, idealWidth: 320, maxHeight: .infinity, alignment: .top)
                    detail(vm)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
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
                vm.load()
                viewModel = vm
            }
            viewModel?.startPolling()
        }
        .onDisappear { viewModel?.stopPolling() }
    }

    // MARK: - Tree

    private func tree(_ vm: ProjectBoardViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Board").font(.headline)
                Spacer()
                Toggle("Show done", isOn: Binding(get: { vm.showDone }, set: { vm.showDone = $0 }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(8)
            Divider()
            if vm.rows.isEmpty {
                ContentUnavailableView(
                    "No targets yet",
                    systemImage: "square.stack.3d.up",
                    description: Text("Claude Code creates the board through the watchtower-project tools.")
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
                        isCollapsed: vm.collapsed.contains(row.id)
                    ) { vm.toggle(row.id) }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowBackground(Color.clear)
                }
                .panelListStyle()
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detail(_ vm: ProjectBoardViewModel) -> some View {
        if let node = vm.selectedNode {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let error = vm.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                    TextField("Title", text: $titleDraft)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                        .onSubmit { vm.rename(titleDraft) }
                    // Status and priority sit on their own row as compact
                    // menus: a segmented picker here took the whole width and
                    // squeezed the intent into a one-letter column.
                    HStack(spacing: 8) {
                        statusMenu(vm, node.target)
                        priorityMenu(vm, node.target)
                        Spacer(minLength: 0)
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
            .onAppear { titleDraft = node.target.text }
            .onChange(of: node.target.id) { titleDraft = node.target.text }
            .onChange(of: node.target.text) { titleDraft = node.target.text }
        } else {
            ContentUnavailableView("Select a target", systemImage: "square.stack.3d.up")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
