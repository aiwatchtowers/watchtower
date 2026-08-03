import SwiftUI

/// Sheet for connecting a new Atlassian site, presented from Settings → Jira.
/// A workspace can have any number of Jira accounts side by side, each
/// granting access via its own OAuth consent flow — this small form kicks off
/// `watchtower jira add`, which opens the loopback-browser consent. Structural
/// copy of `AddSlackAccountView` (house pattern): `addAccount` is awaited
/// directly, so the sheet dismisses on success rather than watching an
/// `isConnecting` transition.
struct AddJiraAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: JiraAccountsViewModel? { appState.jiraAccountsViewModel }

    @State private var label = ""
    /// Optional site hint passed through as `--site`. The CLI's site picker is
    /// an interactive stdin prompt, and the Process this sheet spawns has no
    /// stdin wired — so when a grant reaches several Atlassian sites, naming
    /// one here is the only way the add can complete.
    @State private var site = ""
    /// Set when Cancel is tapped so the awaited `addAccount` (which returns
    /// with a cleared error after the SIGTERM) does NOT auto-dismiss — Cancel
    /// means "let me adjust the form", matching AddSlackAccountView's behavior.
    @State private var cancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Jira Site")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            TextField("Label (optional)", text: $label, prompt: Text("e.g. Work, Client"))
                .textFieldStyle(.roundedBorder)

            TextField("Site (optional)", text: $site, prompt: Text("e.g. acme.atlassian.net"))
                .textFieldStyle(.roundedBorder)

            Text("""
                Opens Atlassian's authorization page in your browser. After you approve, \
                the site is added and syncing starts. Leave Site empty unless your \
                Atlassian account reaches several sites.
                """)
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
        .frame(width: 360, height: 250)
    }

    private func connect() {
        guard let vm else { return }
        cancelled = false
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let trimmedSite = site.trimmingCharacters(in: .whitespaces)
        Task {
            await vm.addAccount(label: trimmed, site: trimmedSite)
            // addAccount is awaited: on success `error` is nil. A user Cancel
            // also clears error (SIGTERM/SIGKILL branch), so gate the dismiss
            // on `cancelled` to keep the sheet open when the flow was
            // cancelled.
            if !cancelled && vm.error == nil {
                dismiss()
            }
        }
    }
}
