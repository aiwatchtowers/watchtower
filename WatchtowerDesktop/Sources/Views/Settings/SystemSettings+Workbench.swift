import SwiftUI
import WatchtowerCore

extension SystemSettings {
    /// Workbench → Default agent (board #399, D1): what a new session, Work
    /// on It and a phone start run; the menus can still pick the other one.
    /// Below it, a pointer to the owner's instructions (Settings → Profile). Kept in its own file so
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
            // Cloud AI settings show both CLI paths; local AI does not.
            if config.workbenchDefaultAgent == .codex, config.aiProvider == "ollama" {
                LabeledContent(ProviderSettingsCopy.path("codex")) {
                    TextField(ProviderSettingsCopy.path("codex"), text: Binding(
                    get: { config.codexPath ?? "" }, set: { config.codexPath = $0.isEmpty ? nil : $0 }
                    ), prompt: Text(ProviderSettingsCopy.autoDetect)).textFieldStyle(.kit)
                }
            }
            HStack {
                Text("Instructions for your agents live in Profile.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open Profile") { appState.openInstructionsSettings() }
                    .buttonStyle(.link).font(.caption)
            }
        }
    }
}
