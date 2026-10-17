import SwiftUI
import WatchtowerCore

/// Settings → System → Workbench: the default agent (board #399, D1) — what a
/// new session, Work on It and a phone start run; the menus can still pick the
/// other one — and the owner's instructions for agents.
struct WorkbenchSettingsSection<CodexPathRow: View>: View {
    @Bindable var config: ConfigService
    /// The Codex CLI path row, shown when Codex is the default agent but not the AI provider.
    let showsCodexPath: Bool
    @ViewBuilder let codexPathRow: () -> CodexPathRow

    var body: some View {
        Section("Workbench") {
            Picker("Default Agent", selection: $config.workbenchDefaultAgent) {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    Text(agent.displayName).tag(agent)
                }
            }
            .help("The agent a new workbench session, Work on It and a start from the phone run. "
                + "The New session and Work on It menus can still start the other one.")
            if showsCodexPath {
                codexPathRow()
            }
            InstructionsSettingsSection()
        }
    }
}
