import AppKit
import SwiftUI
import WatchtowerCore

/// Projects tab: the collapsible two-level panel on the left (projects and
/// standalone terminals, or one project's Board, Documents and sessions) and
/// the selected project's page — or standalone terminal — on the right
/// (spec 2026-09-30-project-workspace-sessions §3).
struct ProjectsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @AppStorage("projects.panelVisible") private var panelVisible = true
    @State private var pendingFolder: URL?
    @State private var sensitiveLocation: String?
    @State private var renamingSession: TerminalSession?
    @State private var deletingSession: TerminalSession?

    var body: some View {
        HStack(spacing: 0) {
            if panelVisible {
                panel
                    .frame(width: 260)
                    .sessionActionDialogs(vm: vm, renaming: $renamingSession, deleting: $deletingSession)
                Divider()
            }
            Group {
                if let standalone = vm.selectedStandalone {
                    StandaloneTerminalView(session: standalone)
                        .id(standalone.id)
                } else if let project = vm.selectedProject {
                    ProjectPageView(vm: vm, project: project)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
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
        .navigationTitle("Projects")
        .onAppear {
            consumeRoute()
            Task { await vm.reload() }
        }
        .onChange(of: appState.pendingProjectRoute) { _, _ in consumeRoute() }
        .alert(
            "Folder in \(sensitiveLocation ?? "")",
            isPresented: Binding(get: { sensitiveLocation != nil }, set: { if !$0 { sensitiveLocation = nil } })
        ) {
            Button("Create anyway") { createPending() }
            Button("Choose another folder", role: .cancel) { pendingFolder = nil }
        } message: {
            Text(
                "Claude Code in the embedded terminal runs as part of Watchtower, so macOS may ask whether "
                    + "Watchtower can access \(sensitiveLocation ?? "this folder"). A folder outside Documents, "
                    + "Desktop, Downloads and cloud storage avoids that prompt."
            )
        }
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
            rename: { renamingSession = $0 },
            close: { session in Task { await vm.close(session) } },
            delete: { deletingSession = $0 }
        )
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            List(selection: listSelection) {
                Section("Projects") {
                    ForEach(vm.summaries) { summary in
                        row(summary)
                            .tag(ProjectsPanelItem.project(summary.id))
                            // A click on the already-selected project (after
                            // Back) changes no selection: drill in anyway.
                            .simultaneousGesture(TapGesture().onEnded { vm.drill(into: summary.id) })
                    }
                }
                TerminalsSection(vm: vm, actions: sessionActions)
            }
            .panelListStyle()
            Divider()
            HStack {
                Button {
                    chooseFolder()
                } label: {
                    Label("New project…", systemImage: "plus")
                }
                .disabled(vm.isCreating)
                if vm.isCreating { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(8)
            if let error = vm.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding([.horizontal, .bottom], 8)
            }
        }
    }

    private var listSelection: Binding<ProjectsPanelItem?> {
        Binding(
            get: {
                if let id = vm.selectedStandaloneID { return .terminal(id) }
                return vm.selectedProjectID.map(ProjectsPanelItem.project)
            },
            set: { item in
                switch item {
                case let .project(id)?:
                    vm.drill(into: id)
                case let .terminal(id)?:
                    guard id != vm.selectedStandaloneID,
                          let session = vm.standaloneSessions.first(where: { $0.id == id }) else { return }
                    Task { await vm.selectStandalone(session) }
                case nil:
                    break
                }
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
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(.secondary)
            Text("Pick a folder to start a project. Claude Code sets it up from there.")
                .foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Create Project"
        guard panel.runModal() == .OK, let url = panel.url?.resolvingSymlinksInPath() else { return }
        pendingFolder = url
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if let location = ProjectFolderPolicy.tccSensitiveLocation(path: url.path, home: home) {
            sensitiveLocation = location
        } else {
            createPending()
        }
    }

    private func createPending() {
        guard let folder = pendingFolder else { return }
        pendingFolder = nil
        sensitiveLocation = nil
        Task { await vm.createProject(folder: folder, name: nil) }
    }

    private func consumeRoute() {
        guard let route = appState.pendingProjectRoute else { return }
        appState.pendingProjectRoute = nil
        vm.reveal(route)
    }
}
