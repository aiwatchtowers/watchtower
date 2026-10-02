import os
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
    /// Set by Cancel, read off the main actor by the running reconnect: a
    /// Cancel that lands before `auth login` is running (during trust-cert or
    /// the launch hop) cannot terminate it, so the flow checks this after
    /// trust-cert and right after the launch. Replaced per reconnect.
    @ObservationIgnored var cancelRequested = OSAllocatedUnfairLock(initialState: false)
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
    @State private var newReactionEmoji = ""
    @State private var newReactionTool = ReactionDictionaryTools.all[0]

    var body: some View {
        Form {
            workspaceSection
            slackAccountsSection
            reactionDictionarySection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        // Keyed on the pool, so a pane opened before the database exists
        // re-configures once it does instead of keeping a nil pool.
        .task(id: appState.databaseManager?.dbPool.path) {
            slackAuth.configure(dbPool: appState.databaseManager?.dbPool)
            await slackAuth.refreshStatus()
        }
        // The Workspaces list below enables/disables, removes and adds
        // accounts through its own VM; re-derive the Workspace status from the
        // table whenever that list changes, or it goes stale (e.g. "Slack
        // connected" after the last account is removed).
        .onChange(of: appState.slackAccountsViewModel?.accounts) { _, _ in
            Task { await slackAuth.refreshStatus() }
        }
        // A refresh can take the disconnect target away while the confirm
        // dialog is open; there is then nothing left to confirm.
        .onChange(of: slackAuth.disconnectTarget?.id) { _, newID in
            if newID == nil { showSlackDisconnectConfirm = false }
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

                if slackAuth.disconnectTarget != nil {
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
            "Disconnect \(disconnectName)?",
            isPresented: $showSlackDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Disconnect \(disconnectName)", role: .destructive) {
                // Re-checked at confirm time: `auth logout` must never run
                // once the target it would remove has gone away.
                if slackAuth.disconnectTarget != nil {
                    disconnectSlack()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the \(disconnectName) connection and stops syncing it. Other connected Slack "
                    + "workspaces keep syncing. Already-synced messages and the AI products built on them "
                    + "(digests, tracks, people cards, inbox items, situations) are kept and stay queryable. "
                    + "Gmail, Calendar, and Jira data are unaffected."
            )
        }
    }

    /// The workspace `auth logout` removes (account #1), named in the dialog.
    private var disconnectName: String {
        slackAuth.disconnectTarget?.displayName ?? "Slack"
    }

    private func disconnectSlack() {
        flow.disconnecting = true
        Task {
            // Stop the daemon first so it isn't mid-sync when the token is
            // removed, then restart it — without a token it skips the Slack
            // phase. Synced data is kept (non-destructive, matches `slack
            // remove` / `auth logout` semantics).
            await flow.daemonManager.stopDaemon()
            if await slackAuth.disconnect() {
                config.reload()
                flow.reconnectResult = nil
                // `auth logout` removed a row: reload the Workspaces list too.
                await appState.slackAccountsViewModel?.refreshAsync()
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
                                if let note = account.syncNote {
                                    Label(note, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
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
                            // Always offered: a healthy account re-consents to pick up a
                            // newly requested permission (sending, chat:write).
                            Button(account.isOK ? "Reconnect" : "Re-login") {
                                Task { await vm.relogin(account) }
                            }
                            .help("Sign in to this workspace again (grants new permissions such as sending messages)")
                            .disabled(vm.isConnecting)
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
        // A pending About you sheet shows once this one has gone.
        .sheet(isPresented: $showAddSlackAccountSheet, onDismiss: addSheetDismissed) {
            AddSlackAccountView()
                .environment(appState)
                .onAppear { appState.isAddingSlackAccount = true }
                .onDisappear { appState.isAddingSlackAccount = false }
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

    /// Reaction commands section — the emoji-to-tool dictionary
    /// (`reaction_command_map`, migration 00063) the owner drives Watchtower
    /// with by reacting to a Slack message. The feature itself ships OFF; this
    /// editor lets the owner curate the dictionary regardless, so it's ready
    /// the moment they enable it.
    private var reactionDictionarySection: some View {
        Section("Reaction commands") {
            if let vm = appState.reactionDictionaryViewModel {
                if vm.mappings.isEmpty {
                    Text("No reaction commands configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.mappings) { mapping in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(SlackEmoji.label(forShortcode: mapping.emoji))
                                Text(ReactionToolCatalog.title(for: mapping.tool))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(vm.trustFor(tool: mapping.tool))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Toggle("Enabled", isOn: Binding(
                                get: { mapping.enabled },
                                set: { newValue in
                                    Task { await vm.setEnabled(emoji: mapping.emoji, enabled: newValue) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            Button("Remove") {
                                Task { await vm.delete(emoji: mapping.emoji) }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                    }
                }

                if let err = vm.error {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    TextField("emoji short-name (e.g. white_check_mark)", text: $newReactionEmoji)
                    Picker("Tool", selection: $newReactionTool) {
                        ForEach(ReactionDictionaryTools.all, id: \.self) { tool in
                            Text(ReactionToolCatalog.title(for: tool)).tag(tool)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    Button("Add mapping") {
                        let emoji = Self.normalizedEmojiShortName(newReactionEmoji)
                        guard !emoji.isEmpty else { return }
                        Task { await vm.upsert(emoji: emoji, tool: newReactionTool) }
                        newReactionEmoji = ""
                    }
                    .disabled(Self.normalizedEmojiShortName(newReactionEmoji).isEmpty)
                }
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Strips whitespace and surrounding `:` so a pasted `:eyes:` becomes the
    /// bare `eyes` Slack's `reactions.list` actually returns.
    private static func normalizedEmojiShortName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
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
        let cancelRequested = OSAllocatedUnfairLock(initialState: false)
        flow.cancelRequested = cancelRequested

        Task.detached {
            // Ensure TLS cert is trusted first
            let trustResult = await Self.runCLIProcess(path: cliPath, arguments: ["auth", "trust-cert"])
            // Cancelled during trust-cert: cancelSlackReconnect already reset
            // the flow; never go on to open the browser. The trust-cert child
            // itself (a seconds-long local step) is left to finish.
            if cancelRequested.withLock({ $0 }) { return }
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
                // Re-checked here: a Cancel since the check above already
                // cleared the line, and must not get it written back.
                if !cancelRequested.withLock({ $0 }) {
                    flow.reconnectResult = "Complete authorization in your browser..."
                }
            }

            // Run auth login (opens browser) — keep reference to process for cancellation
            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["auth", "login"]
            process.environment = Constants.resolvedEnvironment()

            // Published before launch so Cancel can reach it; cancelling
            // checks `isRunning`, so an unlaunched process is left alone —
            // `onLaunch` re-checks the flag once it is running.
            await MainActor.run {
                flow.authProcess = process
            }

            let output = await ProcessPipes.run(process) { launched in
                if cancelRequested.withLock({ $0 }) { launched.terminate() }
            }
            if cancelRequested.withLock({ $0 }) {
                // A newer reconnect may own the slot by now.
                await MainActor.run {
                    if flow.authProcess === process { flow.authProcess = nil }
                    // The login finished just before Cancel landed: the token
                    // is written, so the status must show it.
                    if output.exitCode == 0 {
                        config.reload()
                        Task {
                            slackAuth.clearDisconnectError()
                            await slackAuth.refreshStatus()
                        }
                    }
                }
                return
            }
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run {
                flow.authProcess = nil
                flow.reconnecting = false

                let exitCode = output.exitCode
                if exitCode == -1 {
                    flow.reconnectResult = "Failed to launch: \(stderr)"
                } else if exitCode == 0 {
                    flow.reconnectSuccess = true
                    flow.reconnectResult = "Connected"
                    config.reload()
                    Task {
                        slackAuth.clearDisconnectError()
                        await slackAuth.refreshStatus()
                    }
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
        // Flag first, then the running check: a launch in between is caught
        // by the flow's `onLaunch` re-check.
        flow.cancelRequested.withLock { $0 = true }
        if let process = flow.authProcess, process.isRunning {
            process.terminate()
        }
        flow.authProcess = nil
        flow.reconnecting = false
        flow.reconnectResult = nil
    }

    /// `nonisolated`: a `View` is `@MainActor`, and a main-actor static here
    /// would run its wait on the main thread even when awaited from a
    /// detached task (the onboarding "Connect Slack" freeze).
    nonisolated private static func runCLIProcess(
        path: String,
        arguments: [String]
    ) async -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = Constants.resolvedEnvironment()
        return await ProcessPipes.run(process).trimmed
    }
}

extension SlackConnectionDetail {
    private func addSheetDismissed() {
        appState.isAddingSlackAccount = false
    }
}
