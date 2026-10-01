import AppKit
import SwiftUI
import WatchtowerCore

/// One project: a one-row header (folder, install status, view controls,
/// the "…" menu with Repair / Re-run Setup / Delete) over its workspace — one pane or a split (spec 2026-09-30-project-workspace-sessions §3).
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
            if vm.resyncResults[project.id] != nil || vm.resyncErrors[project.id] != nil {
                resyncSummary
                Divider()
            }
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

    /// One compact row (folder, install status, view controls, the "…"
    /// menu) so the workspace below keeps nearly all the height; an install
    /// error or import note adds a caption line only when there is one.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                } label: {
                    Text(project.folderPath).font(.caption).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.link)
                .help("Reveal in Finder")
                .layoutPriority(-1)
                installStatusIcons
                if vm.isInstalling(projectID: project.id) { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                splitToggle
                moreMenu
            }
            if let installError = vm.installErrors[project.id] {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(installError)
            }
            if let importNote = vm.importNotes[project.id] {
                // Selectable: it ends with the command that retries.
                Text(importNote)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(importNote)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// Repair install, Re-run Setup and Delete…, out of the header row.
    private var moreMenu: some View {
        let status = vm.installStatus[project.id]
        let installing = vm.isInstalling(projectID: project.id)
        return Menu {
            Button {
                Task { await vm.repairInstall(projectID: project.id) }
            } label: {
                Label("Repair install", systemImage: "wrench.and.screwdriver")
            }
            .disabled(installing || status?.needsRepair != true)
            .help(status.map(repairHelp) ?? "Re-install what is missing in the folder")
            Button {
                Task { await vm.resync(projectID: project.id) }
            } label: {
                Label("Re-run Setup", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(installing)
            .help("Attach new documents and re-install what is missing. Never changes the board, comments or sources.")
            Divider()
            Button(role: .destructive) {
                confirmDelete()
            } label: {
                Label("Delete…", systemImage: "trash")
            }
            .disabled(vm.deletingProjectID != nil)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project actions")
        .accessibilityLabel("Project actions")
    }

    private func confirmDelete() {
        guard let pool = appState.databaseManager?.dbPool else { return }
        do {
            deleteSummary = try pool.read { try ProjectDeleteSummary.fetch($0, project: project) }
        } catch {
            // Never confirm a delete against unknown counts.
            deleteSummaryError = error.localizedDescription
        }
    }

    /// What the last Re-run setup did, with its suggestions; selectable,
    /// since a line may end with a command to run.
    private var resyncSummary: some View {
        let error = vm.resyncErrors[project.id].map { [ProjectResynced.Line(text: $0, problem: true)] }
        let lines = error ?? vm.resyncResults[project.id]?.summaryLines ?? []
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text).font(.caption).foregroundStyle(line.problem ? .red : .secondary)
                }
            }
            .textSelection(.enabled)
            Spacer()
            Button {
                vm.dismissResync(projectID: project.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(8)
    }

    /// The install state as small icons with tooltips: installed, needs
    /// Repair (in the "…" menu), Claude Code CLI not found.
    @ViewBuilder
    private var installStatusIcons: some View {
        if let status = vm.installStatus[project.id] {
            if !status.claudeFound && !status.mcp { claudeNotFoundIcon }
            if status.needsRepair {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("The folder install is incomplete — Repair install is in the … menu.\n\(repairHelp(status))")
                    .accessibilityLabel("Install incomplete")
            } else if status.claudeFound || status.mcp {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help("Installed: \(repairHelp(status))")
                    .accessibilityLabel("Installed")
            }
        }
    }

    private func repairHelp(_ status: ProjectInstallStatus) -> String {
        "Skill \(status.skill) · hook \(status.hook ? "on" : "missing") · "
            + "drift hook \(status.stopHook ? "on" : "missing") · MCP \(status.mcp ? "on" : "missing")"
    }

    /// Repair cannot register the MCP server without `claude`: a warning
    /// icon whose menu names the gap and copies the manual command instead
    /// of a Repair that always fails.
    private var claudeNotFoundIcon: some View {
        let command = ProjectInstallStatus.manualMCPCommand(
            projectID: project.id, folder: project.folderPath, cliPath: Constants.findCLIPath() ?? "watchtower"
        )
        return Menu {
            Text("Claude Code CLI not found")
            Button("Copy MCP Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
        } label: {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Claude Code CLI not found. Install Claude Code, then run:\n\(command)")
        .accessibilityLabel("Claude Code CLI not found")
    }

    private var splitToggle: some View {
        let isSplit = vm.layout(projectID: project.id).isSplit
        return Button {
            vm.toggleSplit(projectID: project.id)
        } label: {
            Image(systemName: isSplit ? "rectangle" : "rectangle.split.2x1")
        }
        .buttonStyle(.borderless)
        .help(isSplit ? "Show one pane" : "Split: show two panes side by side")
        .accessibilityLabel(isSplit ? "Single Pane" : "Split")
    }
}
