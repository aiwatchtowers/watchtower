import SwiftUI
import WatchtowerCore

/// "Work on it" (spec 2026-09-30-project-workspace-sessions §4): opens the
/// target's most recent session (resumed, reopened if closed), or starts a
/// new Claude Code session on it with the fixed work-on prompt. The target's
/// title names the session in the panel; it never reaches the command line.
struct WorkOnTargetButton: View {
    let target: Target
    /// Icon only (a board card) or a labelled button (the detail pane).
    let compact: Bool
    /// A card shows it on hover and when selected; hidden it takes no clicks.
    let isVisible: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.projectsViewModel
        let existing = hasSession(vm)
        let title = existing ? "Open Its Session" : "Work on It"
        Button {
            Task { await vm?.workOn(targetID: Int64(target.id), targetText: target.text) }
        } label: {
            if compact {
                Image(systemName: existing ? "arrow.right.circle" : "play.circle")
            } else {
                Label(title, systemImage: existing ? "arrow.right.circle" : "play.circle")
            }
        }
        .buttonStyle(.borderless)
        .help(existing ? "Open the Claude Code session for this target" : "Start a Claude Code session for this target")
        .accessibilityLabel(title)
        .opacity(isVisible ? 1 : 0)
        .disabled(!isVisible || vm == nil)
    }

    private func hasSession(_ vm: ProjectsViewModel?) -> Bool {
        guard let vm, let projectID = target.projectID else { return false }
        return TerminalSessionPolicy.sessionForTarget(Int64(target.id), in: vm.terminalSessions[projectID] ?? []) != nil
    }
}
