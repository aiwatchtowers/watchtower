import SwiftUI
import WatchtowerCore

/// Settings → Assistant tools card: the registry's write tools and their
/// trust. External tools (Jira) are locked to "ask" — AGENT-03.
struct AssistantToolsSettingsSection: View {
    @State private var viewModel = AssistantToolsViewModel()

    var body: some View {
        Section {
            if viewModel.rows.isEmpty && !viewModel.isLoading {
                Text("No tools listed. Is the watchtower CLI available?").foregroundStyle(.secondary)
            }
            ForEach(viewModel.rows) { row in
                toolRow(row)
            }
            if let error = viewModel.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Assistant tools")
        } footer: {
            Text("Write tools create proposals you approve in the chat. \"Execute without approval\" skips the card "
                 + "for that tool; it can never be enabled for tools that write outside this Mac.")
        }
        .task { await viewModel.load() }
    }

    private func toolRow(_ row: AssistantToolRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.name).font(.body.monospaced())
                if row.external {
                    Text("external")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
                Spacer()
                executeToggle(for: row)
            }
            Text(row.description).font(.caption).foregroundStyle(.secondary)
            Text("Surfaces: \(row.surfaces.joined(separator: ", "))").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func executeToggle(for row: AssistantToolRow) -> some View {
        Toggle("Execute without approval", isOn: executeBinding(for: row))
            .labelsHidden()
            .disabled(row.external)
            .help(row.external
                  ? "External tools always need your approval."
                  : "When on, the assistant's proposals with this tool run immediately and show as done.")
    }

    private func executeBinding(for row: AssistantToolRow) -> Binding<Bool> {
        Binding(
            get: { row.trust == "execute" },
            set: { on in Task { await viewModel.setTrust(row.name, execute: on) } }
        )
    }
}
