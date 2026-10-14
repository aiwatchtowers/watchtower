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
            Text("Write tools create proposals you approve in the chat. A checked surface runs that tool without "
                 + "approval on that surface only; it can never be enabled for tools that write outside this Mac.")
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
            }
            Text(row.description).font(.caption).foregroundStyle(.secondary)
            if !row.surfaces.isEmpty {
                HStack(spacing: 12) {
                    Text("Run without approval in:").font(.caption).foregroundStyle(.secondary)
                    ForEach(row.surfaces, id: \.self) { surface in
                        executeToggle(for: row, surface: surface)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// One switch per surface the tool is on: trust is per (tool, surface).
    private func executeToggle(for row: AssistantToolRow, surface: String) -> some View {
        Toggle(AssistantToolSurface.label(for: surface), isOn: executeBinding(for: row, surface: surface))
            .toggleStyle(.checkbox)
            .font(.caption)
            .disabled(row.isLockedToAsk)
            .help(row.external
                  ? "External tools always need your approval."
                  : row.alwaysAsk
                    ? "Bulk changes always need your approval."
                    : "When on, the assistant's proposals with this tool in "
                        + "\(AssistantToolSurface.label(for: surface)) run immediately and show as done.")
    }

    private func executeBinding(for row: AssistantToolRow, surface: String) -> Binding<Bool> {
        Binding(
            get: { row.executes(on: surface) },
            set: { on in Task { await viewModel.setTrust(row.name, surface: surface, execute: on) } }
        )
    }
}
