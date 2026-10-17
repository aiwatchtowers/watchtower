import SwiftUI
import WatchtowerCore

/// Settings → Profile → claude.ai tools (#737): the account's connectors the
/// main chat can use and the owner's switches. State lives in
/// `AppState.claudeAIConnectors`; this view only shows it.
struct ClaudeAIConnectorsSection: View {
    let model: ClaudeAIConnectorsModel

    /// Where a connector the chat lists as not connected gets connected.
    private static let connectURL = URL(string: "https://claude.ai/customize/connectors")

    var body: some View {
        Section {
            if let file = model.file, !file.available {
                // Go's reasons are whole sentences ("claude.ai tools need the Claude provider.").
                Text(file.unavailableReason.isEmpty ? "claude.ai tools are off in the chat." : file.unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Connectors", isOn: Binding(
                get: { model.switches.connectors },
                set: { on in Task { await model.setAllEnabled(on) } }
            ))
            .disabled(model.isWriting)
            if model.file == nil {
                Text("No connectors listed yet. They appear after a chat turn on the Claude provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.servers) { server in
                serverRow(server)
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("claude.ai tools")
        } footer: {
            Text("The main chat can use your claude.ai account's connectors; anything that writes through one "
                 + "waits for your approval. Switches apply to new chat turns — a turn already running keeps "
                 + "the tools it started with.")
        }
        .task { model.reload() }
    }

    private func serverRow(_ server: ClaudeAIConnectorsFile.Server) -> some View {
        let switchedOn = model.switches.connectors && model.isEnabled(server.name)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(server.name)
                Text(ClaudeAIConnectorsModel.statusText(server.status, switchedOn: switchedOn))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if server.status == .needsAuth, let url = Self.connectURL {
                    Link("Connect on claude.ai", destination: url).font(.caption)
                }
                Toggle(server.name, isOn: Binding(
                    get: { model.isEnabled(server.name) },
                    set: { on in Task { await model.setEnabled(name: server.name, on) } }
                ))
                .labelsHidden()
                .disabled(model.isWriting || !model.switches.connectors)
            }
            let tools = ClaudeAIConnectorsModel.toolsText(server.tools)
            if !tools.isEmpty {
                Text(tools).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}
