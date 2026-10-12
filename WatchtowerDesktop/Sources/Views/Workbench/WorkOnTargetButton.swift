import SwiftUI
import WatchtowerCore

/// "Work on it" (spec 2026-09-30-project-workspace-sessions §4): opens the
/// target's most recent session (resumed), or starts a new session of the
/// default agent (board #399, D1) on it with the fixed work-on prompt; the
/// target menu's "Work on It with …" picks another agent. The target's
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
        let session = Self.session(of: target, in: vm)
        let existing = session != nil
        let title = Self.title(existing: existing)
        let icon = existing ? "arrow.right.circle" : "play.circle"
        let button = Button {
            Self.start(target, vm: vm)
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
        .help(AgentChoicePresentation.workOnHelp(existing: session?.kind.agent, defaultAgent: vm?.defaultAgent ?? .claude))
        .accessibilityLabel(title)
        .opacity(isVisible ? 1 : 0)
        .disabled(!isVisible || vm == nil)
        .accessibilityHidden(!isVisible)
    }

    /// The button's and the target menu's label.
    static func title(existing: Bool) -> String {
        existing ? "Open Its Session" : "Work on It"
    }

    /// Opens `target`'s session or starts one: the button's and the target
    /// menu's action. `agent` nil is the default agent (`workOn`).
    static func start(_ target: Target, vm: WorkbenchesViewModel?, agent: AgentKind? = nil) {
        Task {
            await vm?.workOn(targetID: Int64(target.id), targetText: target.text, projectID: target.workbenchID,
                             agent: agent)
        }
    }

    /// Whether `target` already has a session in its workbench: the button
    /// and the target menu label themselves "Open Its Session" then.
    static func hasSession(_ target: Target, in vm: WorkbenchesViewModel?) -> Bool {
        session(of: target, in: vm) != nil
    }

    /// The session Work on It would open.
    static func session(of target: Target, in vm: WorkbenchesViewModel?) -> TerminalSession? {
        guard let vm, let projectID = target.workbenchID else { return nil }
        return TerminalSessionPolicy.sessionForTarget(Int64(target.id), in: vm.terminalSessions[projectID] ?? [])
    }

    /// The target menu's "Work on It with …": the agents other than the
    /// default, each disabled when its CLI is known to be missing.
    static func otherAgents(_ target: Target, vm: WorkbenchesViewModel?) -> [AgentChoice] {
        guard let vm, let projectID = target.workbenchID else { return [] }
        return AgentChoicePresentation.workOnOthers(defaultAgent: vm.defaultAgent) {
            vm.agentAvailable($0, projectID: projectID)
        }
    }
}
