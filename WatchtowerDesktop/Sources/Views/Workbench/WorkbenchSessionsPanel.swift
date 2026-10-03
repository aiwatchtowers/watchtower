import SwiftUI
import WatchtowerCore

/// The left panel's level 2 (spec 2026-09-30-project-workspace-sessions §3):
/// one header row (the workbench switcher, New session), the owner asks
/// waiting (`OwnerAskStackSection`, spec 2026-10-03 Part 8), a SESSIONS label
/// in the app sidebar's style, then the project's sessions. The session on
/// screen is a tab of the workspace: filled with its backdrop, it runs on
/// into the page beside it (`panelTab(isSelected:)`, `panelSurface()`).
/// Board and Files are picked in a pane's own header (`WorkspacePaneView`).
struct WorkbenchSessionsPanel: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    let actions: SessionRowActions
    let switcherActions: WorkbenchSwitcherActions

    var body: some View {
        let sessions = vm.drilledSessions
        let stack = vm.asks.stack(projectID: project.id)
        let closed = vm.asks.closedCounts[project.id] ?? [:]
        VStack(alignment: .leading, spacing: 0) {
            header
            OwnerAskStackSection(vm: vm, project: project)
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
                ForEach(vm.sessionRows(sessions)) { row in
                    TerminalSessionRow(
                        row: row,
                        actions: actions,
                        openAsks: stack.count(session: row.id),
                        closedAsks: (closed[row.id] ?? 0) > 0
                            ? OwnerAskClosedButton(vm: vm, projectID: project.id, sessionID: row.id, count: closed[row.id] ?? 0)
                            : nil
                    )
                    .panelTab(isSelected: vm.panelSelection == .session(row.id))
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
                Task { await vm.newSessionOnPage() }
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

/// One terminal session in the panel: its state dot and caption ("waiting
/// for you", "not started · 5m"), and the target it works on. A workbench's
/// rows also count the session's open asks and offer "▸ N closed"; that
/// button sits outside the row's open click, which would start the session.
struct TerminalSessionRow: View {
    let row: SessionSwitcherPresentation.Row
    let actions: SessionRowActions
    var openAsks = 0
    var closedAsks: OwnerAskClosedButton?

    private var session: TerminalSession { row.session }

    var body: some View {
        HStack(spacing: 4) {
            opener
            if openAsks > 0 {
                Text("\(openAsks)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(Color.accentColor.opacity(0.2), in: Capsule())
                    .help("\(openAsks) open ask\(openAsks == 1 ? "" : "s")")
                    .accessibilityLabel("\(openAsks) open ask\(openAsks == 1 ? "" : "s")")
            }
            closedAsks
        }
        .listRowSeparator(.hidden)
        .help(row.state.isLive ? session.title : "Not running — click to start")
        .contextMenu {
            Button("Rename…") { actions.rename(session) }
            Divider()
            Button("Delete…", role: .destructive) { actions.delete(session) }
        }
    }

    private var opener: some View {
        HStack(spacing: 6) {
            SessionLiveDot(state: row.state)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).lineLimit(1).truncationMode(.tail)
                if let caption = row.caption {
                    // A live caption repeats the dot's label for VoiceOver.
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityHidden(row.state.isLive)
                }
                if let badge = row.badge {
                    Text(badge).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { actions.open(session) })
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(session) }
    }
}

/// A session's state dot: green while its process runs (working or not
/// reported), orange while its agent waits for the owner or for approval,
/// hollow when not running — the panel's rows, both session switchers and
/// the go-to palette draw the same one.
struct SessionLiveDot: View {
    let state: SessionSwitcherPresentation.State

    var body: some View {
        Image(systemName: state.isLive ? "circle.fill" : "circle")
            .font(.system(size: 7))
            .foregroundStyle(color)
            .accessibilityLabel(state.label)
    }

    private var color: Color {
        switch state {
        case .running, .working: .green
        case .waitingForOwner, .needsApproval: .orange
        case .notStarted: .secondary
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
