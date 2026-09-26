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
/// For `http`, the owner picks OAuth (default, recommended) or manual
/// headers. OAuth hides the header editor; Add first creates the row
/// (disabled, no secret), then hands off to `ExternalConnectionsViewModel
/// .signIn` for the loopback-browser consent flow — a long-running,
/// cancellable step (see `Cancel` above), so this sheet stays open and
/// awaits it like `AddSlackAccountView` rather than dismissing right after
/// the row is created.
///
/// The secret is entered as key/value rows (environment variables for a stdio
/// server, headers for a manual-http one) and serialized by
/// `ExternalConnectionSecretBuilder`; it still reaches the CLI via stdin only
/// (QC-03). Switching Kind keeps the typed rows and only relabels the section
/// — the same key/value pairs are sent as env vars or headers accordingly.
/// Arguments go through `CommandArgsTokenizer`, so a quoted path with a space
/// survives as one argument; an unclosed quote is reported to the owner
/// instead of silently becoming an empty argument.
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
    /// Only meaningful for `kind == "http"` — OAuth (default) hides the header
    /// editor and hands the connection straight to `signIn` after Add; manual
    /// keeps the existing header-entry flow.
    @State private var httpAuthMode: HTTPAuthMode = .oauth
    /// Local validation failure (quoting, secret encoding) — distinct from the
    /// view model's CLI error so the two never overwrite each other.
    @State private var inputError: String?
    /// Set when Cancel is tapped so the awaited `addConnection` (which returns
    /// with a cleared error after the SIGTERM) does NOT auto-dismiss — mirrors
    /// `AddSlackAccountView`.
    @State private var cancelled = false

    private var isHTTP: Bool { kind == "http" }
    private var useOAuth: Bool { isHTTP && httpAuthMode == .oauth }

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

            kindSpecificFields

            if !useOAuth {
                secretEditor
            }

            Spacer()

            actionBar

            if let inputError {
                Text(inputError)
                    .font(.caption)
                    .foregroundStyle(.red)
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

    /// stdio: command + arguments. http: server URL plus the OAuth/manual
    /// sign-in picker. Split out of `body` to keep its closure short.
    @ViewBuilder
    private var kindSpecificFields: some View {
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

            Picker("Sign-in", selection: $httpAuthMode) {
                ForEach(HTTPAuthMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)

            Text(
                httpAuthMode == .oauth
                    ? "Opens the server's authorization page in your browser after Add."
                    : "Enter headers (e.g. a static API key) below instead of signing in."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// While a CLI call is in flight: progress + Cancel (cancels an OAuth
    /// sign-in via `cancelSignIn()`; a no-op if the in-flight call is the
    /// plain `add`, which has no cancellable process). Otherwise: the Add
    /// button. Split out of `body` to keep its closure short.
    private var actionBar: some View {
        HStack {
            if vm?.isBusy == true {
                ProgressView().controlSize(.small)
                Text(useOAuth ? "Signing in..." : "Adding...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    cancelled = true
                    vm?.cancelSignIn()
                }
            } else {
                Spacer()
                Button("Add") {
                    add()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
        }
    }

    /// Kind-adaptive key/value rows: env vars for stdio, headers for http. The
    /// row list scrolls past a few entries so the Add button never leaves the
    /// screen. Row fields bind through `binding(for:_:)` (lookup by id) rather
    /// than `ForEach($secretPairs)`, so removing a row from its own button can
    /// never leave a live binding pointing at a shifted element.
    private var secretEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isHTTP ? "Headers (optional)" : "Environment variables (optional)")
                .font(.subheadline)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(secretPairs) { pair in
                        HStack {
                            TextField(
                                isHTTP ? "Header" : "Variable",
                                text: binding(for: pair.id, \.key),
                                prompt: Text(isHTTP ? "Authorization" : "API_KEY")
                            )
                            .textFieldStyle(.roundedBorder)
                            SecureField("Value", text: binding(for: pair.id, \.value), prompt: Text("value"))
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
                }
            }
            .frame(maxHeight: 180)
            Button(isHTTP ? "Add header" : "Add variable") {
                secretPairs.append(SecretPair())
            }
            .buttonStyle(.plain)
            Text("Stored in a 0600 file, never on the command line.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// A binding to one field of the row with `id`, resolved by lookup on
    /// every access. A binding whose row has since been removed reads "" and
    /// writes nowhere — no crash, no write into a neighbouring row.
    private func binding(for id: UUID, _ keyPath: WritableKeyPath<SecretPair, String>) -> Binding<String> {
        Binding(
            get: { secretPairs.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                if let index = secretPairs.firstIndex(where: { $0.id == id }) {
                    secretPairs[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func add() {
        guard let vm else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCommand = command.trimmingCharacters(in: .whitespaces)
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)

        let args: [String]
        let secretJSON: String?
        do {
            args = try CommandArgsTokenizer.tokenize(argsText)
            secretJSON = useOAuth
                ? nil
                : try ExternalConnectionSecretBuilder.json(
                    kind: kind,
                    pairs: secretPairs.map { (key: $0.key, value: $0.value) }
                )
        } catch ExternalConnectionInputError.unclosedQuote {
            inputError = "Arguments contain a quote that is never closed."
            return
        } catch {
            inputError = "Could not encode the secret: \(error.localizedDescription)"
            return
        }
        inputError = nil
        cancelled = false

        Task {
            await vm.addConnection(
                name: trimmedName,
                kind: kind,
                command: trimmedCommand,
                args: args,
                url: trimmedURL,
                secretJSON: secretJSON,
                useOAuth: useOAuth
            )
            // addConnection is awaited: on success (add, and sign-in when
            // useOAuth) `error` is nil. A user Cancel during sign-in also
            // clears error (SIGTERM/SIGKILL branch), so gate the dismiss on
            // `cancelled` to keep the sheet open when the flow was cancelled.
            if !cancelled && vm.error == nil {
                dismiss()
            }
        }
    }
}

/// http-only choice between signing in via OAuth (default, recommended) and
/// entering headers manually.
private enum HTTPAuthMode: String, CaseIterable, Identifiable {
    case oauth
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .oauth: return "Sign in with OAuth (recommended)"
        case .manual: return "Headers (manual)"
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
