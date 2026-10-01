import AppKit
import SwiftUI
import WatchtowerCore

/// One project: header (folder, install status, Repair, Split) over its
/// workspace — one pane or a split (spec 2026-09-30-project-workspace-sessions §3).
struct ProjectPageView: View {
    @Bindable var vm: ProjectsViewModel
    let project: Project
    @Environment(AppState.self) private var appState
    @State private var deleteSummary: ProjectDeleteSummary?
    @State private var deleteSummaryError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // Session actions start from any pane (a pane picker, Open
            // terminal): their errors show here, once, whatever is on screen.
            if let error = vm.sessionErrors[project.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Divider()
            }
            WorkspaceAreaView(vm: vm, project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: project.id) { await vm.refreshInstallStatus(projectID: project.id) }
        .confirmationDialog(
            deleteSummary?.title ?? "",
            isPresented: Binding(get: { deleteSummary != nil }, set: { if !$0 { deleteSummary = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                let id = project.id
                Task { await vm.deleteProject(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteSummary?.message ?? "")
        }
        .alert(
            "Could not delete the project",
            isPresented: Binding(
                get: { vm.deleteError != nil },
                set: { if !$0 { vm.deleteError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(vm.deleteError ?? "")
        }
        .alert(
            "Could not read the project",
            isPresented: Binding(get: { deleteSummaryError != nil }, set: { if !$0 { deleteSummaryError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteSummaryError ?? "")
        }
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
                ProjectBoardLanguageMenu(vm: vm, project: project)
                if let installError = vm.installErrors[project.id] {
                    Text(installError).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                if let importNote = vm.importNotes[project.id] {
                    // Selectable: it ends with the command that retries.
                    Text(importNote).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                }
            }
            Spacer()
            installBadge
            Button(role: .destructive) {
                guard let pool = appState.databaseManager?.dbPool else { return }
                do {
                    deleteSummary = try pool.read { try ProjectDeleteSummary.fetch($0, project: project) }
                } catch {
                    // Never confirm a delete against unknown counts.
                    deleteSummaryError = error.localizedDescription
                }
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(vm.deletingProjectID != nil)
            splitToggle
        }
        .padding(10)
    }

    @ViewBuilder
    private var installBadge: some View {
        if let status = vm.installStatus[project.id] {
            HStack(spacing: 8) {
                if !status.claudeFound && !status.mcp { claudeNotFoundLabel }
                if status.needsRepair {
                    Button {
                        Task { await vm.repairInstall(projectID: project.id) }
                    } label: {
                        Label("Repair install", systemImage: "wrench.and.screwdriver")
                    }
                    .disabled(vm.repairing.contains(project.id))
                    .help(repairHelp(status))
                } else if status.claudeFound || status.mcp {
                    Label("Installed", systemImage: "checkmark.seal").foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }

    private func repairHelp(_ status: ProjectInstallStatus) -> String {
        "Skill \(status.skill) · hook \(status.hook ? "on" : "missing") · "
            + "drift hook \(status.stopHook ? "on" : "missing") · MCP \(status.mcp ? "on" : "missing")"
    }

    /// Repair cannot register the MCP server without `claude`; name the gap
    /// and hand over the manual command instead of a Repair that always fails.
    private var claudeNotFoundLabel: some View {
        let command = ProjectInstallStatus.manualMCPCommand(
            projectID: project.id, folder: project.folderPath, cliPath: Constants.findCLIPath() ?? "watchtower"
        )
        return Label("Claude Code CLI not found", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .font(.caption)
            .help("Install Claude Code, then run:\n\(command)")
            .contextMenu {
                Button("Copy MCP Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
    }

    private var splitToggle: some View {
        let isSplit = vm.layout(projectID: project.id).isSplit
        return Button {
            vm.toggleSplit(projectID: project.id)
        } label: {
            Label(isSplit ? "Single Pane" : "Split", systemImage: isSplit ? "rectangle" : "rectangle.split.2x1")
        }
        .help(isSplit ? "Show one pane" : "Show two panes side by side")
    }
}
