import SwiftUI
import WatchtowerCore

/// The New session menus' entries (board #399, D1): one per agent, an agent
/// whose CLI is known to be missing disabled with a hint.
struct NewSessionMenuItems: View {
    let vm: WorkbenchesViewModel
    let projectID: Int64
    let start: (AgentKind) -> Void

    var body: some View {
        ForEach(AgentChoicePresentation.newSession { vm.agentAvailable($0, projectID: projectID) }) { choice in
            Button(choice.title) { start(choice.agent) }
                .disabled(!choice.isAvailable)
                .help(choice.hint ?? "")
        }
    }
}
