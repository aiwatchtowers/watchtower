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
                List(vm.rows, selection: Binding(get: { vm.selectedTargetID }, set: { vm.select($0) })) { row in
                    rowView(vm, row)
                }
                .panelListStyle()
            }
        }
    }

    private func rowView(_ vm: ProjectBoardViewModel, _ row: ProjectBoardRow) -> some View {
        let t = row.node.target
        return HStack(spacing: 6) {
            if row.hasChildren {
                Button { vm.toggle(row.id) } label: {
                    Image(systemName: vm.collapsed.contains(row.id) ? "chevron.right" : "chevron.down")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 10)
            }
            Image(systemName: t.statusIcon).foregroundStyle(color(t.statusColor))
            Text(t.text.components(separatedBy: "\n").first ?? t.text).lineLimit(1)
            Spacer(minLength: 4)
            if row.node.unreadForOwner > 0 {
                badge("\(row.node.unreadForOwner)", systemImage: "bubble.left.fill", color: .blue)
            }
            if row.node.openComments > 0 {
                badge("\(row.node.openComments)", systemImage: "text.bubble", color: .orange)
            }
            if !row.node.documents.isEmpty {
                badge("\(row.node.documents.count)", systemImage: "doc.text", color: .secondary)
            }
            if t.progress > 0, t.progress < 1 {
                Text("\(Int(t.progress * 100))%").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 14)
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(color)
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
                    Picker("Status", selection: Binding(
                        get: { node.target.status },
                        set: { vm.setStatus($0) }
                    )) {
                        ForEach(ProjectBoardViewModel.editableStatuses, id: \.self) { status in
                            Text(statusName(status)).tag(status)
                        }
                    }
                    .pickerStyle(.segmented)
                    ProgressView(value: node.target.progress)
                    if !node.target.intent.isEmpty {
                        Text(node.target.intent).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
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

    private func statusName(_ status: String) -> String {
        switch status {
        case "todo": return "To Do"
        case "in_progress": return "In Progress"
        case "blocked": return "Blocked"
        case "done": return "Done"
        case "dismissed": return "Dismissed"
        default: return status.capitalized
        }
    }

    private func color(_ name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "red": return .red
        case "green": return .green
        case "gray": return .gray
        case "purple": return .purple
        default: return .secondary
        }
    }
}
