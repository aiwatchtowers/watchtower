import SwiftUI
import WatchtowerCore

/// Slack detail pane in the Connections tab — the legacy single-workspace
/// connect/reconnect/disconnect block plus the multi-account Slack Workspaces
/// list (`slack_accounts` table, migration 00048).
struct SlackConnectionDetail: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    @State private var daemonManager = DaemonManager()
    @State private var slackReconnecting = false
    @State private var slackReconnectResult: String?
    @State private var slackReconnectSuccess = false
    @State private var slackAuthProcess: Process?
    @State private var slackAuth = SlackAuthService()
    @State private var slackDisconnecting = false
    @State private var showSlackDisconnectConfirm = false
    @State private var showAddSlackAccountSheet = false
    @State private var slackAccountPendingRemoval: SlackAccount?

    var body: some View {
        Form {
            workspaceSection
            slackAccountsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .onAppear {
            slackAuth.checkStatus()
        }
    }

    private var workspaceSection: some View {
        Section("Workspace") {
            HStack {
                Image(systemName: slackAuth.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                    .foregroundStyle(slackAuth.isConnected ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Text(slackAuth.isConnected ? "Slack connected" : "Slack not connected")
                Spacer()

                Button {
                    reconnectSlack()
                } label: {
                    HStack(spacing: 4) {
                        if slackReconnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(slackReconnecting
                            ? "Connecting..."
                            : (slackAuth.isConnected ? "Reconnect Slack" : "Connect Slack"))
                    }
                }
                .disabled(slackReconnecting || slackDisconnecting)

                if slackReconnecting {
                    Button("Cancel") {
                        cancelSlackReconnect()
                    }
                }

                if slackAuth.isConnected {
                    Button(role: .destructive) {
                        showSlackDisconnectConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            if slackDisconnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(slackDisconnecting ? "Disconnecting..." : "Disconnect")
                        }
                    }
                    .disabled(slackReconnecting || slackDisconnecting)
                }
            }

            if let result = slackReconnectResult {
                HStack {
                    Image(systemName: slackReconnectSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(slackReconnectSuccess ? .green : .red)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(slackReconnectSuccess ? .green : .red)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            if let err = slackAuth.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .confirmationDialog(
            "Disconnect Slack?",
            isPresented: $showSlackDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect Slack", role: .destructive) {
                disconnectSlack()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the Slack connection and stops syncing. Already-synced Slack messages and the AI "
                    + "products built on them (digests, tracks, people cards, inbox items, situations) are kept "
                    + "and stay queryable. Gmail, Calendar, and Jira data are unaffected."
            )
        }
    }

    private func disconnectSlack() {
        slackDisconnecting = true
        Task {
            // Stop the daemon first so it isn't mid-sync when the token is
            // removed, then restart it — without a token it skips the Slack
            // phase. Synced data is kept (non-destructive, matches `slack
            // remove` / `auth logout` semantics).
            await daemonManager.stopDaemon()
            await slackAuth.disconnect()
            if slackAuth.error == nil {
                config.reload()
                slackReconnectResult = nil
            }
            await daemonManager.startDaemon()
            slackDisconnecting = false
        }
    }

    /// Slack Workspaces section — the multi-account Slack connections
    /// (`slack_accounts` table, migration 00048), each independently granting
    /// access via its own OAuth consent and carrying its own namespaced
    /// identity.
    ///
    /// The removal confirmation copy explicitly states data is KEPT — unlike
    /// Google's removal, `slack remove` is non-destructive: it drops the token
    /// and marks the row removed/disabled but leaves already-synced messages,
    /// digests, and situations in place. The legacy single-account Slack
    /// "Disconnect" in `workspaceSection` now shares the same non-destructive
    /// semantics (`auth logout` → `removeSlackAccount`).
    private var slackAccountsSection: some View {
        Section("Slack Workspaces") {
            if let vm = appState.slackAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No Slack workspaces connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName)
                                if !account.teamDomain.isEmpty {
                                    Text("\(account.teamDomain).slack.com")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Circle()
                                .fill(slackAccountStatusColor(account))
                                .frame(width: 8, height: 8)
                                .help(account.isOK ? "Connected" : (account.error.isEmpty ? account.status : account.error))
                            Toggle("Enabled", isOn: Binding(
                                get: { account.enabled },
                                set: { newValue in
                                    Task { await vm.setEnabled(account, enabled: newValue) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(vm.isConnecting)
                            if !account.isOK {
                                Button("Re-login") {
                                    Task { await vm.relogin(account) }
                                }
                                .disabled(vm.isConnecting)
                            }
                            Button("Remove") {
                                slackAccountPendingRemoval = account
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .disabled(vm.isConnecting)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Add Slack Workspace") {
                    showAddSlackAccountSheet = true
                }
                .disabled(vm.isConnecting)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddSlackAccountSheet) {
            AddSlackAccountView()
                .environment(appState)
        }
        .confirmationDialog(
            "Remove \(slackAccountPendingRemoval?.displayName ?? "this workspace")?",
            isPresented: Binding(
                get: { slackAccountPendingRemoval != nil },
                set: { if !$0 { slackAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Workspace", role: .destructive) {
                if let account = slackAccountPendingRemoval {
                    Task { await appState.slackAccountsViewModel?.remove(account) }
                }
                slackAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Disconnects the workspace. Already-synced messages, digests, and "
                    + "situations stay in Watchtower."
            )
        }
    }

    private func slackAccountStatusColor(_ account: SlackAccount) -> Color {
        if account.isOK { return .green }
        if account.isRevoked { return .red }
        return .orange
    }

    private func reconnectSlack() {
        guard let cliPath = Constants.findCLIPath() else {
            slackReconnectResult = "watchtower CLI not found"
            slackReconnectSuccess = false
            return
        }

        slackReconnecting = true
        slackReconnectResult = nil
        slackReconnectSuccess = false

        Task.detached {
            // Ensure TLS cert is trusted first
            let trustResult = await Self.runCLIProcess(path: cliPath, arguments: ["auth", "trust-cert"])
            if trustResult.exitCode != 0 {
                await MainActor.run {
                    slackReconnecting = false
                    slackReconnectResult = trustResult.stderr.isEmpty
                        ? "Failed to set up secure connection"
                        : String(trustResult.stderr.prefix(200))
                }
                return
            }

            await MainActor.run {
                slackReconnectResult = "Complete authorization in your browser..."
            }

            // Run auth login (opens browser) — keep reference to process for cancellation
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["auth", "login"]
            process.environment = Constants.resolvedEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    slackReconnecting = false
                    slackReconnectResult = "Failed to launch: \(error.localizedDescription)"
                }
                return
            }

            await MainActor.run {
                slackAuthProcess = process
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _ = String(data: stdoutData, encoding: .utf8) // consume stdout

            await MainActor.run {
                slackAuthProcess = nil
                slackReconnecting = false

                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    slackReconnectSuccess = true
                    slackReconnectResult = "Connected"
                    config.reload()
                    slackAuth.checkStatus()
                } else if exitCode == 15 || exitCode == 9 {
                    // SIGTERM / SIGKILL — user cancelled
                    slackReconnectResult = nil
                } else {
                    slackReconnectResult = stderr.isEmpty
                        ? "Authentication failed (exit \(exitCode))"
                        : String(stderr.prefix(200))
                }
            }
        }
    }

    private func cancelSlackReconnect() {
        if let process = slackAuthProcess, process.isRunning {
            process.terminate()
        }
        slackAuthProcess = nil
        slackReconnecting = false
        slackReconnectResult = nil
    }

    private static func runCLIProcess(path: String, arguments: [String]) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (-1, "", error.localizedDescription)
        }

        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }
}
