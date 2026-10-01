import AppKit
import SwiftUI
import WatchtowerCore

/// A level-1 row of the Projects panel: a project, or a standalone terminal.
enum ProjectsPanelItem: Hashable {
    case project(Int64)
    case terminal(Int64)
}

/// A folder the owner picked, held while the TCC warning is on screen.
private enum PendingFolder {
    case project(URL)
    case terminal(TerminalSession.Kind, URL)
}

/// Projects tab: the collapsible, resizable two-level panel on the left
/// (projects and standalone terminals, or one project's sessions) and the
/// selected project's page — or standalone terminal — on the right
/// (spec 2026-09-30-project-workspace-sessions §3).
struct ProjectsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @AppStorage("projects.panelVisible") private var panelVisible = true
    @AppStorage("projects.panelWidth") private var panelWidth = PanelResizeHandle.defaultWidth
    @State private var dragPanelWidth: Double?
    @State private var pendingFolder: PendingFolder?
    @State private var sensitiveLocation: String?
    @State private var renamingSession: TerminalSession?
    @State private var deletingSession: TerminalSession?

    var body: some View {
        HStack(spacing: 0) {
            if panelVisible {
                panel.frame(width: dragPanelWidth ?? PanelResizeHandle.clamp(panelWidth))
                PanelResizeHandle(width: $panelWidth, liveWidth: $dragPanelWidth)
            }
            Group {
                if let standalone = vm.selectedStandalone {
                    StandaloneTerminalView(session: standalone, actions: sessionActions)
                        .id(standalone.id)
                } else if let project = vm.selectedProject {
                    ProjectPageView(vm: vm, project: project)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sessionActionDialogs(vm: vm, renaming: $renamingSession, deleting: $deletingSession)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { panelVisible.toggle() }
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle Projects Panel")
                .accessibilityLabel("Toggle Projects Panel")
            }
        }
        .onAppear {
            consumeRoute()
            Task { await vm.reload() }
        }
        .onChange(of: appState.pendingProjectRoute) { _, _ in consumeRoute() }
        .alert(
            "Folder in \(sensitiveLocation ?? "")",
            isPresented: Binding(get: { sensitiveLocation != nil }, set: { if !$0 { sensitiveLocation = nil } })
        ) {
            Button(isTerminalPending ? "Open anyway" : "Create anyway") { startPending() }
            Button("Choose another folder", role: .cancel) { pendingFolder = nil }
        } message: {
            Text(
                "The embedded terminal runs as part of Watchtower, so macOS may ask whether "
                    + "Watchtower can access \(sensitiveLocation ?? "this folder"). A folder outside Documents, "
                    + "Desktop, Downloads and cloud storage avoids that prompt."
            )
        }
    }

    private var isTerminalPending: Bool {
        if case .terminal? = pendingFolder { return true }
        return false
    }

    @ViewBuilder
    private var panel: some View {
        if let project = vm.drilledProject {
            ProjectSessionsPanel(vm: vm, project: project, actions: sessionActions)
        } else {
            projectList
        }
    }

    private var sessionActions: SessionRowActions {
        SessionRowActions(
            open: { session in
                Task {
                    if session.projectID == nil {
                        await vm.selectStandalone(session)
                    } else {
                        await vm.showFromPanel(sessionID: session.id)
                    }
                }
            },
            rename: { renamingSession = $0 },
            close: { session in Task { await vm.close(session) } },
            delete: { deletingSession = $0 }
        )
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            projectListHeader
            List(selection: listSelection) {
                Section {
                    ForEach(vm.summaries) { summary in
                        row(summary)
                            .tag(ProjectsPanelItem.project(summary.id))
                            .listRowSeparator(.hidden)
                            // A click on the already-selected project (after
                            // Back) changes no selection: drill in anyway.
                            .simultaneousGesture(TapGesture().onEnded { vm.drill(into: summary.id) })
                    }
                }
                TerminalsSection(vm: vm, actions: sessionActions, chooseFolder: chooseTerminalFolder)
            }
            .panelListStyle()
            if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
    }

    /// The chat history's header shape ("Chats" + New Chat).
    private var projectListHeader: some View {
        HStack(spacing: 6) {
            Text("Projects").font(.headline)
            Spacer(minLength: 4)
            if vm.isCreating { ProgressView().controlSize(.small) }
            Button {
                chooseFolder()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(vm.isCreating)
            .help("New project…")
            .accessibilityLabel("New project…")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var listSelection: Binding<ProjectsPanelItem?> {
        Binding(
            get: {
                if let id = vm.selectedStandaloneID { return .terminal(id) }
                return vm.selectedProjectID.map(ProjectsPanelItem.project)
            },
            set: { item in
                // A terminal row opens on its own click (`SessionRowActions.open`);
                // arrow keys only move the highlight (VoiceOver has the row's action).
                if case let .project(id)? = item { vm.drill(into: id) }
            }
        )
    }

    private func row(_ summary: ProjectSummary) -> some View {
        let badge = summary.unreadAgentComments + vm.revisedDocumentCount(for: summary)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.project.name).font(.body)
                Text(summary.project.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(summary.openTargets) open · \(summary.inProgressTargets) in progress")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if badge > 0 {
                Text("\(badge)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.blue, in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pick a folder to start a project. Claude Code sets it up from there.")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        guard let url = runFolderPanel(prompt: "Create Project", canCreate: true) else { return }
        confirmLocation(of: .project(url), path: url.path)
    }

    /// New terminal → "… in Folder…": the same TCC warning as a project.
    private func chooseTerminalFolder(_ kind: TerminalSession.Kind) {
        guard let url = runFolderPanel(prompt: "Open Terminal", canCreate: false) else { return }
        confirmLocation(of: .terminal(kind, url), path: url.path)
    }

    private func runFolderPanel(prompt: String, canCreate: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = canCreate
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.resolvingSymlinksInPath()
    }

    private func confirmLocation(of pending: PendingFolder, path: String) {
        pendingFolder = pending
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if let location = ProjectFolderPolicy.tccSensitiveLocation(path: path, home: home) {
            sensitiveLocation = location
        } else {
            startPending()
        }
    }

    private func startPending() {
        guard let pending = pendingFolder else { return }
        pendingFolder = nil
        sensitiveLocation = nil
        switch pending {
        case let .project(folder):
            Task { await vm.createProject(folder: folder, name: nil) }
        case let .terminal(kind, folder):
            Task { await vm.newStandalone(kind: kind, folder: folder) }
        }
    }

    private func consumeRoute() {
        guard let route = appState.pendingProjectRoute else { return }
        appState.pendingProjectRoute = nil
        vm.reveal(route)
    }
}
