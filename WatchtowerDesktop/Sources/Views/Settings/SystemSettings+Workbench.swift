import SwiftUI
import WatchtowerCore

extension SystemSettings {
    /// Workbench → Default agent (board #399, D1): what a new session, Work
    /// on It and a phone start run; the menus can still pick the other one.
    /// Below it, the owner's instructions for agents. Kept in its own file so
    /// SystemSettings.swift stays under the fan-out gate.
    var workbenchSection: some View {
        Section("Workbench") {
            Picker("Default Agent", selection: $config.workbenchDefaultAgent) {
                ForEach(AgentKind.allCases, id: \.self) { agent in
                    Text(agent.displayName).tag(agent)
                }
            }
            .help("The agent a new workbench session, Work on It and a start from the phone run. "
                + "The New session and Work on It menus can still start the other one.")
            // The AI section shows it already when Codex is the AI provider.
            if config.workbenchDefaultAgent == .codex, selectedProviderID != "codex" {
                codexCLIPathRow
            }
            InstructionsSettingsSection()
        }
    }
}
