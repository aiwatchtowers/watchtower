import AppKit
import SwiftUI
import WatchtowerCore

/// Projects tab: the project list on the left, the selected project's page on
/// the right (spec §6.1).
struct ProjectsView: View {
    @Bindable var vm: ProjectsViewModel
    @Environment(AppState.self) private var appState
    @State private var pendingFolder: URL?
    @State private var sensitiveLocation: String?

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            Group {
                if let project = vm.selectedProject {
                    ProjectPageView(vm: vm, project: project)
                } else {
                    emptyState
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
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

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $vm.selectedProjectID) {
                ForEach(vm.summaries) { summary in
                    row(summary).tag(Optional(summary.id))
                }
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
