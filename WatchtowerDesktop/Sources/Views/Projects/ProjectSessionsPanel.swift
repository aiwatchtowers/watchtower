import SwiftUI
import WatchtowerCore

/// The left panel's level 2 (spec 2026-09-30-project-workspace-sessions §3):
/// Back, the project's name, Board and Documents, then its sessions and
/// "New session".
struct ProjectSessionsPanel: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project
    let actions: SessionRowActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                vm.drilledProjectID = nil
            } label: {
                Label("Projects", systemImage: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .padding([.horizontal, .top], 8)
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            List(selection: selection) {
                Label("Board", systemImage: "square.grid.3x2").tag(WorkspacePane.board)
                Label("Documents", systemImage: "doc.text").tag(WorkspacePane.documents)
                Section("Sessions") {
                    ForEach(vm.drilledSessions) { session in
                        TerminalSessionRow(session: session, isLive: vm.isLive(session), actions: actions)
                            .tag(WorkspacePane.session(session.id))
                    }
                }
            }
            .panelListStyle()
            if let error = vm.sessionErrors[project.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }
            Divider()
            Button {
                Task { await vm.newPanelSession() }
            } label: {
                Label("New session", systemImage: "plus")
            }
            .padding(8)
        }
        .task(id: project.id) { await vm.loadSessions(projectID: project.id) }
    }

    private var selection: Binding<WorkspacePane?> {
        Binding(
            get: { vm.panelSelection },
            set: { item in
                guard let item, item != vm.panelSelection else { return }
                Task { await vm.showFromPanel(item) }
            }
        )
    }
}

/// What a session row's Rename…, Close and Delete… do; the panel owns the
/// sheet and the confirmation (`sessionActionDialogs`).
struct SessionRowActions {
    let rename: (TerminalSession) -> Void
    let close: (TerminalSession) -> Void
    let delete: (TerminalSession) -> Void
}

/// One terminal session in the panel: a dot when its process runs, dimmed
/// when closed, the target it works on, and a close button on hover.
struct TerminalSessionRow: View {
    let session: TerminalSession
    let isLive: Bool
    let actions: SessionRowActions
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isLive ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(isLive ? Color.green : Color.secondary)
                .accessibilityLabel(isLive ? "Running" : "Not running")
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1).truncationMode(.tail)
                if let targetID = session.targetID {
                    Text("#\(targetID)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isLive && hovering {
                Button {
                    actions.close(session)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Close session (stops the process, keeps it listed)")
                .accessibilityLabel("Close session")
            }
        }
        .foregroundStyle(session.isClosed ? .secondary : .primary)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(session.isClosed ? "Closed — click to reopen" : session.title)
        .contextMenu {
            Button("Rename…") { actions.rename(session) }
            Button("Close") { actions.close(session) }.disabled(!isLive)
            Divider()
            Button("Delete…", role: .destructive) { actions.delete(session) }
        }
    }
}

extension View {
    /// The Rename sheet and the Delete confirmation behind `SessionRowActions`.
    func sessionActionDialogs(
        vm: ProjectsViewModel,
        renaming: Binding<TerminalSession?>,
        deleting: Binding<TerminalSession?>
    ) -> some View {
        modifier(SessionActionDialogs(vm: vm, renaming: renaming, deleting: deleting))
    }
}

private struct SessionActionDialogs: ViewModifier {
    let vm: ProjectsViewModel
    @Binding var renaming: TerminalSession?
    @Binding var deleting: TerminalSession?

    func body(content: Content) -> some View {
        content
            .sheet(item: $renaming) { session in
                RenameSessionSheet(session: session) { title in
                    Task { await vm.rename(session, to: title) }
                }
            }
            .confirmationDialog(
                "Delete “\(deleting?.title ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Session", role: .destructive) {
                    if let session = deleting { Task { await vm.delete(session) } }
                    deleting = nil
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: {
                Text("Its process stops and it leaves the list. Claude Code's own transcript is kept.")
            }
    }
}

private struct RenameSessionSheet: View {
    let session: TerminalSession
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename session").font(.headline)
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .onAppear { title = session.title }
    }

    private var trimmed: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}
