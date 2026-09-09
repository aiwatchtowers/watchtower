import SwiftUI
import WatchtowerCore

/// Sheet for adding a new Quick Connection (owner-managed external MCP
/// server), presented from Settings → Quick Connections. Mirrors
/// `AddSlackAccountView`'s shape: the connect call is `async` and awaited
/// directly, so the sheet dismisses on success rather than watching a
/// separate "connecting" transition.
///
/// A connection is always created disabled — `ExternalConnectionsViewModel`
/// enforces that via the CLI, this sheet has no enable toggle of its own.
///
/// The secret is entered as key/value rows (environment variables for a stdio
/// server, headers for an http one) and serialized by
/// `ExternalConnectionSecretBuilder`; it still reaches the CLI via stdin only
/// (QC-03). Arguments go through `CommandArgsTokenizer`, so a quoted path with
/// a space survives as one argument.
struct AddExternalConnectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: ExternalConnectionsViewModel? { appState.externalConnectionsViewModel }

    @State private var name = ""
    @State private var kind = "stdio"
    @State private var command = ""
    @State private var argsText = ""
    @State private var url = ""
    @State private var secretPairs: [SecretPair] = []

    private var isHTTP: Bool { kind == "http" }

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
                TextField(
                    "Arguments (optional, quote a value containing spaces)",
                    text: $argsText,
                    prompt: Text("e.g. -y trello-mcp")
                )
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

            secretEditor

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
        .frame(width: 440)
    }

    /// Kind-adaptive key/value rows: env vars for stdio, headers for http.
    private var secretEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isHTTP ? "Headers (optional)" : "Environment variables (optional)")
                .font(.subheadline)
            ForEach($secretPairs) { $pair in
                HStack {
                    TextField(
                        isHTTP ? "Header" : "Variable",
                        text: $pair.key,
                        prompt: Text(isHTTP ? "Authorization" : "API_KEY")
                    )
                    .textFieldStyle(.roundedBorder)
                    SecureField("Value", text: $pair.value, prompt: Text("value"))
                        .textFieldStyle(.roundedBorder)
                    Button {
                        secretPairs.removeAll { $0.id == pair.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove row")
                }
            }
            Button(isHTTP ? "Add header" : "Add variable") {
                secretPairs.append(SecretPair())
            }
            .buttonStyle(.plain)
            Text("Stored in a 0600 file, never on the command line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        guard let vm else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        let args = CommandArgsTokenizer.tokenize(argsText)
        let secretJSON = ExternalConnectionSecretBuilder.json(
            kind: kind,
            pairs: secretPairs.map { (key: $0.key, value: $0.value) }
        )

        Task {
            await vm.addConnection(
                name: trimmedName,
                kind: kind,
                command: trimmedCommand,
                args: args,
                url: trimmedURL,
                secretJSON: secretJSON
            )
            if vm.error == nil {
                dismiss()
            }
        }
    }
}

/// One key/value row of the secret editor — an environment variable for a
/// stdio server, a header for an http one. Identity is per row so removing
/// one never shifts a neighbour's binding.
private struct SecretPair: Identifiable {
    let id = UUID()
    var key = ""
    var value = ""
}
