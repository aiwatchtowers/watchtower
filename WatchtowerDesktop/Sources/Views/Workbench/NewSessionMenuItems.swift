import SwiftUI
import WatchtowerCore

/// The New session menus' entries (board #399, D1; board #229): one per
/// agent, an agent whose CLI is known to be missing disabled with a hint,
/// then the same agents under "In This Folder" and "In Its Own Worktree"
/// (the plain entry is Automatic). The worktree entry is disabled with the
/// reason when the folder's last git status says none can be made. On a
/// bench of several folders (spec 2026-11-18 §6.4) the top entries start in
/// the context folder, each other folder gets an `in <folder>` submenu with
/// the same agents, and the placement submenus list the folders.
struct NewSessionMenuItems: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    /// The folder is nil for the top entries: the page's context
    /// (`WorkbenchesViewModel.shortcutFolder`).
    let start: (AgentKind, WorktreeChoice, NewSessionFolder.Context?) -> Void

    var body: some View {
        let choices = AgentChoicePresentation.newSessionAgentChoices(policy: vm.managedPolicy()) {
            vm.agentAvailable($0, projectID: projectID)
        }
        let menu = vm.newSessionMenu(projectID: projectID)
        agentButtons(choices, placement: .auto, folder: nil)
        if let menu, !menu.otherFolders.isEmpty {
            Divider()
            ForEach(menu.otherFolders, id: \.folderID) { item in
                Menu(item.title) { agentButtons(choices, placement: .auto, folder: .menu(folderID: item.folderID)) }
            }
        }
        Divider()
        placementMenu(.folder, choices: choices, folders: menu?.placementFolders ?? [])
        placementMenu(.worktree, choices: choices, folders: menu?.placementFolders ?? [])
    }

    private func agentButtons(
        _ choices: [AgentChoice], placement: WorktreeChoice, folder: NewSessionFolder.Context?
    ) -> some View {
        ForEach(choices) { choice in
            Button(choice.title) { start(choice.agent, placement, folder) }
                .disabled(!choice.isAvailable)
                .help(choice.hint ?? "")
        }
    }

    /// One placement submenu: the agents (one folder), or a submenu per
    /// folder with them, each disabled with its folder's worktree reason.
    @ViewBuilder
    private func placementMenu(
        _ placement: WorktreeChoice,
        choices: [AgentChoice],
        folders: [SessionNestingPresentation.NewSessionMenu.FolderItem]
    ) -> some View {
        if folders.isEmpty {
            let reason = reason(placement, folderID: nil)
            Menu(SessionStartPlacementPresentation.menuTitle(placement)) {
                agentButtons(choices, placement: placement, folder: nil)
            }
            .disabled(reason != nil)
            .help(reason.map(SessionStartPlacementPresentation.disabledHelp) ?? "")
        } else {
            Menu(SessionStartPlacementPresentation.menuTitle(placement)) {
                ForEach(folders, id: \.folderID) { item in
                    let reason = reason(placement, folderID: item.folderID)
                    Menu(item.title) {
                        agentButtons(choices, placement: placement, folder: .menu(folderID: item.folderID))
                    }
                    .disabled(reason != nil)
                    .help(reason.map(SessionStartPlacementPresentation.disabledHelp) ?? "")
                }
            }
        }
    }

    private func reason(_ placement: WorktreeChoice, folderID: Int64?) -> String? {
        placement == .worktree ? vm.worktreeUnavailableReason(projectID: projectID, folderID: folderID) : nil
    }
}
