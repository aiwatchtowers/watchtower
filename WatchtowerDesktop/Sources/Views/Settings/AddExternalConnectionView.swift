import SwiftUI

/// Sheet for adding a new Quick Connection (owner-managed external MCP
/// server), presented from Settings → Quick Connections. Mirrors
/// `AddSlackAccountView`'s shape: the connect call is `async` and awaited
/// directly, so the sheet dismisses on success rather than watching a
/// separate "connecting" transition.
///
/// A connection is always created disabled — `ExternalConnectionsViewModel`
/// enforces that via the CLI, this sheet has no enable toggle of its own.
struct AddExternalConnectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: ExternalConnectionsViewModel? { appState.externalConnectionsViewModel }

    @State private var name = ""
    @State private var kind = "stdio"
    @State private var command = ""
    @State private var argsText = ""
    @State private var url = ""
    @State private var secretJSON = ""

    private var canAdd: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if kind == "stdio" {
            return !command.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return !url.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Connection")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            TextField("Name", text: $name, prompt: Text("e.g. Trello"))
                .textFieldStyle(.roundedBorder)

            Picker("Kind", selection: $kind) {
                Text("stdio (local process)").tag("stdio")
                Text("http (remote server)").tag("http")
            }
            .pickerStyle(.segmented)

            if kind == "stdio" {
                TextField("Command", text: $command, prompt: Text("e.g. npx"))
                    .textFieldStyle(.roundedBorder)
                TextField("Arguments (space-separated, optional)", text: $argsText, prompt: Text("e.g. -y trello-mcp"))
                    .textFieldStyle(.roundedBorder)

                Text(
                    "Watchtower will run this command as a local subprocess whenever the "
                        + "connection is enabled. Only add commands you trust — a stdio "
                        + "connection has the same access to your Mac as any other process "
                        + "you run yourself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                TextField("Server URL", text: $url, prompt: Text("https://example.com/mcp"))
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Secret (JSON, optional)", text: $secretJSON, prompt: Text(#"{"env":{"API_KEY":"..."}}"#))
                    .textFieldStyle(.roundedBorder)
                Text("Stored in a 0600 file, never on the command line. Shape: {\"env\":{...}} or {\"headers\":{...}}.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if vm?.isBusy == true {
                    ProgressView().controlSize(.small)
                    Text("Adding...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") {
                    add()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd || vm?.isBusy == true)
            }

            if let err = vm?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func add() {
        guard let vm else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        let trimmedSecret = secretJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let args = argsText.split(separator: " ").map(String.init)

        Task {
            await vm.addConnection(
                name: trimmedName,
                kind: kind,
                command: trimmedCommand,
                args: args,
                url: trimmedURL,
                secretJSON: trimmedSecret.isEmpty ? nil : trimmedSecret
            )
            if vm.error == nil {
                dismiss()
            }
        }
    }
}
