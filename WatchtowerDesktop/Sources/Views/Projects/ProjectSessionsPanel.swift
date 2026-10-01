import SwiftUI
import WatchtowerCore

/// The left panel's level 2 (spec 2026-09-30-project-workspace-sessions §3):
/// one header row (Back, the project's name, New session), then Board and
/// Documents and the project's sessions — shaped like the chat history
/// (`ChatSidebarView`).
struct ProjectSessionsPanel: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project
    let actions: SessionRowActions

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: selection) {
                Section {
                    PanelRowLabel("Board", systemImage: "square.grid.2x2").tag(WorkspacePane.board)
                    PanelRowLabel("Documents", systemImage: "doc.text").tag(WorkspacePane.documents)
                }
                Section("Sessions") {
                    ForEach(vm.drilledSessions) { session in
                        TerminalSessionRow(session: session, isLive: vm.isLive(session), actions: actions)
                            .tag(WorkspacePane.session(session.id))
                    }
                }
            }
            .panelListStyle()
        }
        .task(id: project.id) { await vm.loadSessions(projectID: project.id) }
    }

    /// The chat history's header shape ("Chats" + New Chat) with Back in front.
    private var header: some View {
        HStack(spacing: 6) {
            Button {
                vm.drilledProjectID = nil
            } label: {
                Image(systemName: "chevron.backward")
            }
            .buttonStyle(.borderless)
            .help("Back to Projects")
            .accessibilityLabel("Back to Projects")
            Text(project.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            Button {
                Task { await vm.newPanelSession() }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New session")
            .accessibilityLabel("New session")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Board and Documents select through the List; a session row opens on
    /// its own click (`SessionRowActions.open`), which also reaches the row
    /// already highlighted but not running. Arrow keys therefore move the
    /// highlight without starting a session (VoiceOver has the row's action).
    private var selection: Binding<WorkspacePane?> {
        Binding(
            get: { vm.panelSelection },
            set: { item in
                guard let item, item == .board || item == .documents, item != vm.panelSelection else { return }
                Task { await vm.showFromPanel(item) }
            }
        )
    }
}

/// What a session row's click, Rename…, Close and Delete… do; the page owns
/// the sheet and the confirmation (`sessionActionDialogs`).
struct SessionRowActions {
    let open: (TerminalSession) -> Void
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
            // The click target excludes the close button: a close must not
            // also reopen the session.
            HStack(spacing: 6) {
                Image(systemName: isLive ? "circle.fill" : "circle")
                    .font(.system(size: 7))
                    .foregroundStyle(isLive ? Color.green : Color.secondary)
                    .frame(width: PanelRowLabel.iconWidth)
                    .accessibilityLabel(isLive ? "Running" : "Not running")
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).lineLimit(1).truncationMode(.tail)
                    if let targetID = session.targetID {
                        Text("#\(targetID)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { actions.open(session) })
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.open(session) }
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
        .listRowSeparator(.hidden)
        .onHover { hovering = $0 }
        .help(session.isClosed ? "Closed — click to reopen" : isLive ? session.title : "Not running — click to start")
        .contextMenu {
            Button("Rename…") { actions.rename(session) }
            Button("Close") { actions.close(session) }.disabled(!isLive)
            Divider()
            Button("Delete…", role: .destructive) { actions.delete(session) }
        }
    }
}

/// A Board/Documents row: a small secondary icon in a fixed column, so the
/// text lines up with the session rows' text below it.
struct PanelRowLabel: View {
    static let iconWidth: CGFloat = 16
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
            Text(title).lineLimit(1)
        }
        .listRowSeparator(.hidden)
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
