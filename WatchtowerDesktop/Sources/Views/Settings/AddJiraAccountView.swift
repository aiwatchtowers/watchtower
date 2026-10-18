import SwiftUI
import WatchtowerCore

/// Sheet for connecting a new Atlassian site, presented from Settings → Jira.
/// A workspace can have any number of Jira accounts side by side, each
/// granting access via its own OAuth consent flow — this small form kicks off
/// `watchtower jira add`, which opens the loopback-browser consent. Structural
/// copy of `AddSlackAccountView` (house pattern): the connect is awaited
/// directly, so on success the sheet turns into the board step (#572,
/// `JiraBoardChoiceView`) rather than watching an `isConnecting` transition.
/// The connect's daemon restart is held while that step is up and applied
/// once when the sheet goes away (`JiraAccountsViewModel.finishBoardStep`).
struct AddJiraAccountView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    private var vm: JiraAccountsViewModel? { appState.jiraAccountsViewModel }

    /// `.deferred` from onboarding: the connect must not restart the daemon
    /// mid-setup (`DaemonRestartPolicy`). Settings keeps the default.
    let daemonPolicy: DaemonRestartPolicy

    init(daemonPolicy: DaemonRestartPolicy = .restart) {
        self.daemonPolicy = daemonPolicy
    }

    /// Optional site hint passed through as `--site`. The CLI's site picker is
    /// an interactive stdin prompt, and the Process this sheet spawns has no
    /// stdin wired — so when a grant reaches several Atlassian sites, naming
    /// one here is the only way the add can complete.
    @State private var site = ""
    /// Set when Cancel is tapped so the awaited connect (which returns
    /// with a cleared error after the SIGTERM) does NOT move on — Cancel
    /// means "let me adjust the form", matching AddSlackAccountView's behavior.
    @State private var cancelled = false
    /// After a successful connect the sheet turns into the board step (#572):
    /// a new site syncs nothing until boards are selected.
    @State private var choosingBoards = false
    /// Account ids read before the connect, so the board step lists the
    /// site it added; nil when the read failed (every enabled site).
    @State private var accountIDsBefore: Set<Int>?
    /// Set on the click, before any await, so a double click starts one connect.
    @State private var starting = false
    /// "Also connect Confluence" (#573): the same consent grants Confluence,
    /// and the board step selects the spaces the owner works in. On by
    /// default; unchecking it keeps the connect Jira-only.
    @State private var withConfluence = true
    /// What the finished connect asked for (the box can change afterwards).
    @State private var connectedConfluence = false

    var body: some View {
        Group {
            if choosingBoards {
                JiraBoardChoiceView(
                    accountIDsBefore: accountIDsBefore, connectConfluence: connectedConfluence
                ) { dismiss() }
                    .padding(20)
                    .frame(width: 420, height: 420)
            } else {
                connectForm
            }
        }
        // Done, Skip or any other way the sheet closes: one restart for the
        // new site and its boards (nothing under onboarding's `.deferred`).
        .onDisappear { vm?.finishBoardStep() }
    }

    private var connectForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add Jira Site")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
            }

            TextField("Site (optional)", text: $site, prompt: Text("e.g. acme.atlassian.net"))
                .textFieldStyle(.roundedBorder)

            Text("""
                Opens Atlassian's authorization page in your browser. After you approve, \
                the site is added under its address (acme for acme.atlassian.net) and you choose the boards to sync. Leave Site \
                empty unless your Atlassian account reaches several sites.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Also connect Confluence", isOn: $withConfluence)
                .toggleStyle(.checkbox)
                .disabled(vm?.isConnecting == true || starting)
                .help("The same sign-in also grants Confluence. The spaces you wrote in or viewed lately become searchable.")

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
                    .disabled(starting)
                }
            }

            if let err = vm?.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                // An Atlassian app without the Confluence API refuses the
                // wider scope set, so a failed connect names the way out.
                if connectedConfluence {
                    Text("Refused by Atlassian? Uncheck Also connect Confluence and try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 360, height: 300)
    }

    private func connect() {
        guard let vm, !starting else { return }
        starting = true
        cancelled = false
        connectedConfluence = withConfluence
        let trimmedSite = site.trimmingCharacters(in: .whitespaces)
        Task {
            let result = await vm.addAccountHoldingRestart(
                site: trimmedSite, withConfluence: connectedConfluence, daemonPolicy: daemonPolicy
            )
            starting = false
            accountIDsBefore = result.accountIDsBefore
            // A user Cancel clears error (SIGTERM/SIGKILL branch) and returns
            // false; `cancelled` also covers a Cancel before the launch.
            if result.connected && !cancelled {
                choosingBoards = true
            }
        }
    }
}
