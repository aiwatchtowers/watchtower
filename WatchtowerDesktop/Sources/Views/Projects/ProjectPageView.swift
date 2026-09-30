import AppKit
import SwiftUI
import WatchtowerCore

/// One project: header (folder, install status, Repair) and the Terminal |
/// Board | Documents panes (spec §6.1).
struct ProjectPageView: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            paneContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: project.id) { await vm.refreshInstallStatus(projectID: project.id) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.headline)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                } label: {
                    Text(project.folderPath).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Reveal in Finder")
            }
            Spacer()
            installBadge
            Picker("", selection: $vm.pane) {
                ForEach(ProjectPane.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .padding(10)
    }

    @ViewBuilder
    private var installBadge: some View {
        if let status = vm.installStatus[project.id], status.needsRepair {
            Button {
                Task { await vm.repairInstall(projectID: project.id) }
            } label: {
                Label("Repair install", systemImage: "wrench.and.screwdriver")
            }
            .disabled(vm.repairing.contains(project.id))
            .help("Skill \(status.skill) · hook \(status.hook ? "on" : "missing") · MCP \(status.mcp ? "on" : "missing")")
        } else if vm.installStatus[project.id] != nil {
            Label("Installed", systemImage: "checkmark.seal").foregroundStyle(.secondary).font(.caption)
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch vm.pane {
        case .terminal:
            ProjectTerminalView(project: project)
        case .board:
            ProjectPanePlaceholder(title: "Board")
        case .documents:
            ProjectDocumentsView(vm: vm)
        }
    }
}

/// A pane that is not built yet in this phase. Task 19 replaces Board.
struct ProjectPanePlaceholder: View {
    let title: String

    var body: some View {
        Text("\(title) — coming next")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
