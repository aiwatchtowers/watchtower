import SwiftUI
import WatchtowerCore

/// The workbench's workspace area with its page screen — Clean Up (board
/// #1107, spec 2026-10-26-worktree-cleanup-screen §3.1) or Agent Settings
/// (board #1150) — over it while one is open. The screen covers the area
/// rather than replacing it: the panes stay in the view tree — hidden, out
/// of hit-testing and accessibility — so a session's terminal is never
/// detached or re-created, and closing the screen shows the workspace
/// exactly as it was.
struct WorkbenchCoveredWorkspace: View {
    @Bindable var vm: WorkbenchesViewModel
    let project: Workbench

    var body: some View {
        let screen = vm.pageScreen(projectID: project.id)
        let covered = screen != nil
        ZStack {
            // An ask filed outside the app has no terminal to sit beside:
            // its drawer takes the page's trailing edge.
            OwnerAskDrawerHost(vm: vm, ask: vm.asks.drawerAsk(projectID: project.id).flatMap { $0.sessionID == nil ? $0 : nil }) {
                WorkspaceAreaView(vm: vm, project: project)
            }
            .opacity(covered ? 0 : 1)
            .allowsHitTesting(!covered)
            .accessibilityHidden(covered)
            switch screen {
            case .cleanUp: CleanupScreenView(vm: vm, project: project)
            case .agentSettings: AgentSettingsScreen(vm: vm, project: project)
            case nil: EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
