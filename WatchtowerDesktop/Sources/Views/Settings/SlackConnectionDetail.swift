import SwiftUI
import WatchtowerCore

/// In-flight Slack auth/reconnect/disconnect state, hoisted out of
/// `SlackConnectionDetail` and owned by `ConnectionsSettings` instead. The
/// Connections tab's detail pane is a `@ViewBuilder switch`, so each service
/// gets its own view identity — switching to another service while a
/// `SlackConnectionDetail`-local `@State` reconnect/disconnect was running
/// would tear that state (and the running CLI process reference) down,
/// orphaning the process and losing the result. Living on `ConnectionsSettings`
/// instead means this state survives switching services, matching the old
/// `GeneralSettings` monolith where it lived for the tab's whole lifetime.
@MainActor
@Observable
final class SlackAuthFlowState {
    var reconnecting = false
    var reconnectResult: String?
    var reconnectSuccess = false
    var authProcess: Process?
    var disconnecting = false
    let daemonManager = DaemonManager()
}

/// Slack detail pane in the Connections tab — the legacy single-workspace
/// connect/reconnect/disconnect block plus the multi-account Slack Workspaces
/// list (`slack_accounts` table, migration 00048).
struct SlackConnectionDetail: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    var flow: SlackAuthFlowState
    @State private var slackAuth = SlackAuthService()
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
                        if flow.reconnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(flow.reconnecting
                            ? "Connecting..."
                            : (slackAuth.isConnected ? "Reconnect Slack" : "Connect Slack"))
                    }
                }
                .disabled(flow.reconnecting || flow.disconnecting)

                if flow.reconnecting {
                    Button("Cancel") {
                        cancelSlackReconnect()
                    }
                }

                if slackAuth.isConnected {
                    Button(role: .destructive) {
                        showSlackDisconnectConfirm = true
                    } label: {
                        HStack(spacing: 4) {
                            if flow.disconnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(flow.disconnecting ? "Disconnecting..." : "Disconnect")
                        }
                    }
                    .disabled(flow.reconnecting || flow.disconnecting)
                }
            }

            if let result = flow.reconnectResult {
                HStack {
                    Image(systemName: flow.reconnectSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(flow.reconnectSuccess ? .green : .red)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(flow.reconnectSuccess ? .green : .red)
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
        flow.disconnecting = true
        Task {
            // Stop the daemon first so it isn't mid-sync when the token is
            // removed, then restart it — without a token it skips the Slack
            // phase. Synced data is kept (non-destructive, matches `slack
            // remove` / `auth logout` semantics).
            await flow.daemonManager.stopDaemon()
            await slackAuth.disconnect()
            if slackAuth.error == nil {
                config.reload()
                flow.reconnectResult = nil
            }
            await flow.daemonManager.startDaemon()
            flow.disconnecting = false
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
            flow.reconnectResult = "watchtower CLI not found"
            flow.reconnectSuccess = false
            return
        }

        flow.reconnecting = true
        flow.reconnectResult = nil
        flow.reconnectSuccess = false

        Task.detached {
            // Ensure TLS cert is trusted first
            let trustResult = await Self.runCLIProcess(path: cliPath, arguments: ["auth", "trust-cert"])
            if trustResult.exitCode != 0 {
                await MainActor.run {
                    flow.reconnecting = false
                    flow.reconnectResult = trustResult.stderr.isEmpty
                        ? "Failed to set up secure connection"
                        : String(trustResult.stderr.prefix(200))
                }
                return
            }

            await MainActor.run {
                flow.reconnectResult = "Complete authorization in your browser..."
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
                    flow.reconnecting = false
                    flow.reconnectResult = "Failed to launch: \(error.localizedDescription)"
                }
                return
            }

            await MainActor.run {
                flow.authProcess = process
            }

            process.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            _ = String(data: stdoutData, encoding: .utf8) // consume stdout

            await MainActor.run {
                flow.authProcess = nil
                flow.reconnecting = false

                let exitCode = process.terminationStatus
                if exitCode == 0 {
                    flow.reconnectSuccess = true
                    flow.reconnectResult = "Connected"
                    config.reload()
                    slackAuth.checkStatus()
                } else if exitCode == 15 || exitCode == 9 {
                    // SIGTERM / SIGKILL — user cancelled
                    flow.reconnectResult = nil
                } else {
                    flow.reconnectResult = stderr.isEmpty
                        ? "Authentication failed (exit \(exitCode))"
                        : String(stderr.prefix(200))
                }
            }
        }
    }

    private func cancelSlackReconnect() {
        if let process = flow.authProcess, process.isRunning {
            process.terminate()
        }
        flow.authProcess = nil
        flow.reconnecting = false
        flow.reconnectResult = nil
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
