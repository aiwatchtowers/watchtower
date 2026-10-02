import SwiftUI
import WatchtowerCore

/// The left panel's level 2 (spec 2026-09-30-project-workspace-sessions §3):
/// one header row (the workbench switcher, New session), a SESSIONS label
/// in the app sidebar's style, then the project's sessions. The session on
/// screen is a tab of the workspace: filled with its backdrop, it runs on
/// into the page beside it (`panelTab(isSelected:)`, `panelSurface()`).
/// Board and Documents are picked in a pane's own header (`WorkspacePaneView`).
struct WorkbenchSessionsPanel: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let actions: SessionRowActions
    let switcherActions: WorkbenchSwitcherActions

    var body: some View {
        let sessions = vm.drilledSessions
        VStack(alignment: .leading, spacing: 0) {
            header
            Text("SESSIONS")
                .sidebarSectionLabel()
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            // No List selection: its highlight would draw over the tab. The
            // tab follows `vm.panelSelection` (the session on screen) and a
            // row opens on its own click (`SessionRowActions.open`), which
            // also reaches the row already highlighted but not running
            // (VoiceOver has the row's action).
            List {
                ForEach(sessions) { session in
                    TerminalSessionRow(session: session, isLive: vm.isLive(session), actions: actions)
                        .panelTab(isSelected: vm.panelSelection == .session(session.id))
                }
                .onMove { vm.moveSessions(sessions, projectID: project.id, from: $0, to: $1) }
            }
            .clearPlainList()
            WorkbenchFilesSection(vm: vm, project: project)
        }
        .task(id: project.id) { await vm.loadSessions(projectID: project.id) }
    }

    /// The chat history's header shape ("Chats" + New Chat), the title being
    /// the workbench switcher (board #250): it fills the width, and its
    /// popover's "All Workbenches" is the way back to level 1.
    private var header: some View {
        HStack(spacing: 6) {
            WorkbenchSwitcher(vm: vm, project: project, actions: switcherActions)
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
}

/// What a session row's click, Rename… and Delete… do; the page owns the
/// sheet and the confirmation (`sessionActionDialogs`).
struct SessionRowActions {
    let open: (TerminalSession) -> Void
    let rename: (TerminalSession) -> Void
    let delete: (TerminalSession) -> Void
}

/// One terminal session in the panel: a dot when its process runs, and the
/// target it works on.
struct TerminalSessionRow: View {
    let session: TerminalSession
    let isLive: Bool
    let actions: SessionRowActions

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isLive ? "circle.fill" : "circle")
                .font(.system(size: 7))
                .foregroundStyle(isLive ? Color.green : Color.secondary)
                .frame(width: 16)
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
        .listRowSeparator(.hidden)
        .help(isLive ? session.title : "Not running — click to start")
        .contextMenu {
            Button("Rename…") { actions.rename(session) }
            Divider()
            Button("Delete…", role: .destructive) { actions.delete(session) }
        }
    }
}

extension View {
    /// The Rename sheet and the Delete confirmation behind `SessionRowActions`.
    func sessionActionDialogs(
        vm: WorkbenchesViewModel,
        renaming: Binding<TerminalSession?>,
        deleting: Binding<TerminalSession?>
    ) -> some View {
        modifier(SessionActionDialogs(vm: vm, renaming: renaming, deleting: deleting))
    }
}

private struct SessionActionDialogs: ViewModifier {
    let vm: WorkbenchesViewModel
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
