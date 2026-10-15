import SwiftUI
import WatchtowerCore

/// The New session menus' entries (board #399, D1; board #229): one per
/// agent, an agent whose CLI is known to be missing disabled with a hint,
/// then the same agents under "In This Folder" and "In Its Own Worktree"
/// (the plain entry is Automatic). The worktree entry is disabled with the
/// reason when the header's last git status says none can be made.
struct NewSessionMenuItems: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let start: (AgentKind, WorktreeChoice) -> Void

    var body: some View {
        let choices = AgentChoicePresentation.newSessionAgentChoices { vm.agentAvailable($0, projectID: projectID) }
        ForEach(choices) { choice in
            Button(choice.title) { start(choice.agent, .auto) }
                .disabled(!choice.isAvailable)
                .help(choice.hint ?? "")
        }
        Divider()
        placementMenu(.folder, choices: choices, reason: nil)
        placementMenu(.worktree, choices: choices, reason: vm.worktreeUnavailableReason(projectID: projectID))
    }

    private func placementMenu(_ placement: WorktreeChoice, choices: [AgentChoice], reason: String?) -> some View {
        Menu(SessionStartPlacementPresentation.menuTitle(placement)) {
            ForEach(choices) { choice in
                Button(choice.title) { start(choice.agent, placement) }
                    .disabled(!choice.isAvailable)
                    .help(choice.hint ?? "")
            }
        }
        .disabled(reason != nil)
        .help(reason.map(SessionStartPlacementPresentation.disabledHelp) ?? "")
    }
}
