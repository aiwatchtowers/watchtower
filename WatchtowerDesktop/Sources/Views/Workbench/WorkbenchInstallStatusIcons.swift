import AppKit
import SwiftUI
import WatchtowerCore

/// The workbench header's install state as small icons with tooltips
/// (installed, needs Repair, older setup, Codex not set up, Claude Code CLI
/// not found), out of `WorkbenchPageView`.
struct WorkbenchInstallStatusIcons: View {
    let vm: WorkbenchesViewModel
    let project: Workbench

    /// The install state as small icons with tooltips: installed, needs
    /// Repair (in the "…" menu), Claude Code CLI not found.
    var body: some View {
        if let status = vm.installStatus[project.id] {
            if !status.claudeFound && !status.mcp { claudeNotFoundIcon }
            if let notice = status.codexSetupNotice(failure: vm.codexSetupErrors[project.id]) {
                codexSetupMenu(notice)
            }
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

    /// Codex is installed but the folder's Codex part was never set up
    /// (board #399): a neutral item, orange only after a failed setup, whose
    /// menu runs the same Codex install as Repair.
    private func codexSetupMenu(_ notice: CodexSetupNotice) -> some View {
        Menu {
            Text(notice.title)
            Button("Set up Codex") { Task { await vm.setUpCodex(projectID: project.id) } }
                .disabled(vm.isInstalling(projectID: project.id))
        } label: {
            Label(notice.title, systemImage: notice.isWarning ? "exclamationmark.triangle" : "plus.circle")
                .font(.caption)
                .foregroundStyle(notice.isWarning ? Color.orange : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(notice.help)
        .accessibilityLabel(notice.title)
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
