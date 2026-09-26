import SwiftUI

/// Sheet for connecting a new Slack workspace, presented from Settings → Slack
/// Workspaces. A workspace can have any number of Slack accounts side by side,
/// each granting access via its own OAuth consent flow — this small form kicks
/// off `watchtower slack add`, which opens the loopback-browser consent.
///
/// Unlike `AddGoogleAccountView` (whose `addAccount` is fire-and-forget and
/// returns a Bool "did it start" flag), `SlackAccountsViewModel.addAccount` is
/// `async` and awaited directly — so this sheet awaits the connect and dismisses
/// on success rather than watching an `isConnecting` transition.
struct AddSlackAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: SlackAccountsViewModel? { appState.slackAccountsViewModel }

    @State private var label = ""
    /// Set when Cancel is tapped so the awaited `addAccount` (which returns with
    /// a cleared error after the SIGTERM) does NOT auto-dismiss — Cancel means
    /// "let me adjust the form", matching AddGoogleAccountView's behavior.
    @State private var cancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Slack Workspace")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            TextField("Label (optional)", text: $label, prompt: Text("e.g. Work, Community"))
                .textFieldStyle(.roundedBorder)

            Text("Opens Slack's authorization page in your browser. After you approve, the workspace is added and syncing starts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                if vm?.isConnecting == true {
                    ProgressView().controlSize(.small)
                    Text("Connecting...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        cancelled = true
                        vm?.cancelConnect()
                    }
                } else {
                    Spacer()
                    Button("Connect") {
                        connect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let err = vm?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 360, height: 200)
    }

    private func connect() {
        guard let vm else { return }
        cancelled = false
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        Task {
            await vm.addAccount(label: trimmed)
            // addAccount is awaited: on success `error` is nil. A user Cancel
            // also clears error (SIGTERM/SIGKILL branch), so gate the dismiss on
            // `cancelled` to keep the sheet open when the flow was cancelled.
            if !cancelled && vm.error == nil {
                dismiss()
            }
        }
    }
}
