import AppKit
import SwiftUI
import WatchtowerCore

/// One workbench: a one-row header (folder › branch, install status, view controls,
/// the "…" menu with Repair / Re-run Setup / Delete) over its workspace — one pane or a split (spec 2026-09-30-project-workspace-sessions §3).
struct WorkbenchPageView: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench
    @Environment(AppState.self) private var appState
    @State private var deleteSummary: WorkbenchDeleteSummary?
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
            // An ask filed outside the app has no terminal to sit beside:
            // its drawer takes the page's trailing edge.
            OwnerAskDrawerHost(vm: vm, ask: vm.asks.drawerAsk(projectID: project.id).flatMap { $0.sessionID == nil ? $0 : nil }) {
                WorkspaceAreaView(vm: vm, project: project)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Open Quickly works while this page is on screen (spec §2 decision 3).
        .background(OpenQuicklyHostView(center: appState.openQuicklyCenter, project: project))
        // Hand to Claude Code (⌥⌘↩) from the popover, the Questions tab or Open Quickly.
        .sheet(item: handoffRequest) { request in
            HandToClaudeSheet(handoff: appState.codeHandoffCenter, request: request)
        }
        .task(id: project.id) { await vm.refreshInstallStatus(projectID: project.id) }
        .task(id: project.id) { await vm.startGitWatching(project: project) }
        // The 5 s poll follows the asks from here; this is the first read.
        .task(id: project.id) { await vm.asks.refreshIfChanged(projectID: project.id) }
        .onChange(of: project.id) { old, _ in vm.stopGitWatching(projectID: old) }
        .onDisappear { vm.stopGitWatching(projectID: project.id) }
        .confirmationDialog(
            deleteSummary?.title ?? "",
            isPresented: Binding(get: { deleteSummary != nil }, set: { if !$0 { deleteSummary = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Workbench", role: .destructive) {
                let id = project.id
                Task { await vm.deleteWorkbench(id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteSummary?.message ?? "")
        }
        .alert(
            "Could not delete the workbench",
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
            "Could not read the workbench",
            isPresented: Binding(get: { deleteSummaryError != nil }, set: { if !$0 { deleteSummaryError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteSummaryError ?? "")
        }
    }

    private var handoffRequest: Binding<CodeHandoffRequest?> {
        let handoff = appState.codeHandoffCenter
        let workbenchID = project.id
        return Binding(get: { handoff.requests[workbenchID] },
                       set: { if $0 == nil { handoff.cancel(workbenchID: workbenchID) } })
    }

    /// One compact row (folder, install status, view controls, the "…"
    /// menu) so the workspace below keeps nearly all the height; an install
    /// error or import note adds a caption line only when there is one.
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                // Breadcrumbs: 📁 ~/folder › ⎇ branch ● ↑2 ▾ (#233).
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                        Text(WorkbenchBranchPresentation.displayPath(project.folderPath, home: NSHomeDirectory()))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                }
                .buttonStyle(.link)
                .help("\(project.folderPath)\nShow in Finder")
                .layoutPriority(-1)
                WorkbenchBranchCrumb(vm: vm, project: project)
                installStatusIcons
                if vm.isInstalling(projectID: project.id) { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
                WorkbenchHeaderControls(vm: vm, project: project, onDelete: confirmDelete)
            }
            if let installError = vm.installErrors[project.id] {
                Text(installError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(installError)
            }
            if let archiveError = vm.archiveSettingErrors[project.id] {
                Text(archiveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(archiveError)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func confirmDelete() {
        guard let pool = appState.databaseManager?.dbPool else { return }
        do {
            deleteSummary = try pool.read { try WorkbenchDeleteSummary.fetch($0, project: project, vocabulary: vm.vocabulary(projectID: project.id)) }
        } catch {
            // Never confirm a delete against unknown counts.
            deleteSummaryError = error.localizedDescription
        }
    }

    /// What the last Re-run setup did, with its suggestions; selectable,
    /// since a line may end with a command to run.
    private var resyncSummary: some View {
        let error = vm.resyncErrors[project.id].map { [WorkbenchResynced.Line(text: $0, problem: true)] }
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
                    .help("The folder install is incomplete — Repair install is in the … menu.\n\(status.repairHelp)")
                    .accessibilityLabel("Install incomplete")
            } else if let notice = status.legacyNotice {
                // A nudge only: nothing migrates until the owner runs it (O6).
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("\(notice)\n\(status.repairHelp)")
                    .accessibilityLabel("Older setup")
            } else if status.claudeFound || status.mcp {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .help("Installed: \(status.repairHelp)")
                    .accessibilityLabel("Installed")
            }
        }
    }

    /// Repair cannot register the MCP server without `claude`: a warning
    /// icon whose menu names the gap and copies the manual command instead
    /// of a Repair that always fails.
    private var claudeNotFoundIcon: some View {
        let command = WorkbenchInstallStatus.manualMCPCommand(
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
}
