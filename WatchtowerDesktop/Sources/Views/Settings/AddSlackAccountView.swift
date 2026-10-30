import SwiftUI
import WatchtowerCore

/// Sheet for connecting a new Slack workspace, presented from Connections → Slack
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

    /// `.deferred` from onboarding: the connect must not restart the daemon
    /// mid-setup (`DaemonRestartPolicy`). Settings keeps the default.
    let daemonPolicy: DaemonRestartPolicy

    init(daemonPolicy: DaemonRestartPolicy = .restart) {
        self.daemonPolicy = daemonPolicy
    }

    /// This sheet started the running sign-in; only that one is cancelled
    /// when the sheet goes away (not a Reconnect started elsewhere).
    @State private var startedSignIn = false
    /// Bumped per Connect: a cancelled attempt finishing late must not clear
    /// `startedSignIn` for a newer one the sheet started meanwhile.
    @State private var signInAttempt = 0

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

            Text("""
                Opens Slack's authorization page in your browser. After you approve, the workspace \
                is added under its Slack name and syncing starts. Rename it in Settings any time.
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
        .frame(width: 360, height: 180)
        // Close, Esc or onboarding moving on mid-connect: no sign-in outlives
        // its sheet (the CLI would wait an hour for the browser), so a
        // reopened sheet can start a new one.
        .onDisappear {
            if startedSignIn { vm?.cancelConnect() }
        }
    }

    private func connect() {
        guard let vm else { return }
        startedSignIn = true
        signInAttempt += 1
        let attempt = signInAttempt
        Task {
            // Only a finished sign-in closes the sheet: a Cancel keeps it open
            // ("let me adjust the form", as AddGoogleAccountView does).
            let outcome = await vm.addAccount(daemonPolicy: daemonPolicy)
            if signInAttempt == attempt { startedSignIn = false }
            if outcome == .succeeded { dismiss() }
        }
    }
}
