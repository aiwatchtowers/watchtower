import SwiftUI
import WatchtowerCore

/// "Work on it" (spec 2026-09-30-project-workspace-sessions §4): opens the
/// target's most recent session (resumed), or starts a
/// new Claude Code session on it with the fixed work-on prompt. The target's
/// title names the session in the panel; it never reaches the command line.
struct WorkOnTargetButton: View {
    let target: Target
    /// Icon only (a board card) or a labelled prominent button (the side panel).
    let compact: Bool
    /// A card shows it on hover and when selected; hidden it takes no clicks.
    let isVisible: Bool
    @Environment(AppState.self) private var appState

    var body: some View {
        let vm = appState.workbenchesViewModel
        let existing = hasSession(vm)
        let title = existing ? "Open Its Session" : "Work on It"
        let icon = existing ? "arrow.right.circle" : "play.circle"
        let button = Button {
            Task { await vm?.workOn(targetID: Int64(target.id), targetText: target.text, projectID: target.workbenchID) }
        } label: {
            if compact {
                Image(systemName: icon)
            } else {
                Label(title, systemImage: icon)
            }
        }
        // The side panel's primary action; a card's icon stays borderless.
        Group {
            if compact {
                button.buttonStyle(.borderless)
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
        .help(existing ? "Open the Claude Code session for this target" : "Start a Claude Code session for this target")
        .accessibilityLabel(title)
        .opacity(isVisible ? 1 : 0)
        .disabled(!isVisible || vm == nil)
        .accessibilityHidden(!isVisible)
    }

    private func hasSession(_ vm: WorkbenchesViewModel?) -> Bool {
        guard let vm, let projectID = target.workbenchID else { return false }
        return TerminalSessionPolicy.sessionForTarget(Int64(target.id), in: vm.terminalSessions[projectID] ?? []) != nil
    }
}
