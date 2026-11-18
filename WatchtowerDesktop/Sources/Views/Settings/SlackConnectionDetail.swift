import os
import SwiftUI
import WatchtowerCore
import DesignKit

/// In-flight Slack auth/reconnect/disconnect state, hoisted out of
/// `SlackConnectionDetail` and owned by `AppState` (`slackAuthFlow`). The
/// Connections tab's detail pane is a `@ViewBuilder switch`, so each service
/// gets its own view identity — switching to another service, or to another
/// tab, while a `SlackConnectionDetail`-local `@State` reconnect/disconnect
/// was running would tear that state (and the running CLI process reference)
/// down, orphaning the process and losing the result. On `AppState` it
/// survives both.
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

/// Slack detail pane in the Connections tab (screens spec
/// `2026-11-15-slack-full-live-screens-design.md` §1): the Slack mode with
/// its Live block on top, then the legacy single-workspace
/// connect/reconnect/disconnect block, the multi-account Slack Workspaces
/// list (`slack_accounts` table, migration 00048) and the reaction commands.
struct SlackConnectionDetail: View {
    @Environment(AppState.self) private var appState
    /// The organization's policy forbids this source (#608): nothing new
    /// connects; existing accounts keep their data.
    private var sourceBlocked: Bool { !appState.managedPolicy.policy.sourceAllowed("slack") }
    @Bindable var config: ConfigService
    var flow: SlackAuthFlowState
    @State private var slackAuth = SlackAuthService()
    @State private var showSlackDisconnectConfirm = false
    @State private var showAddSlackAccountSheet = false
    @State private var slackAccountPendingRemoval: SlackAccount?
    @State private var accountBeingRenamed: AccountRenameTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                modeSection
                workspaceSection
                FileVaultLine()
                slackAccountsSection
                reactionDictionarySection
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .detailBackground()
        // Keyed on the pool, so a pane opened before the database exists
        // re-configures once it does instead of keeping a nil pool.
        .task(id: appState.databaseManager?.dbPool.path) {
            slackAuth.configure(dbPool: appState.databaseManager?.dbPool)
            await slackAuth.refreshStatus()
        }
        .onAppear { appState.slackLiveStatusCenter?.refreshIfStale() }
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

    /// The chip, the summary and the Live block; the ages re-read the clock
    /// once a minute.
    @ViewBuilder private var modeSection: some View {
        if let center = appState.slackLiveStatusCenter {
            TimelineView(.everyMinute) { context in
                SlackModeSection(
                    presentation: SlackModePresentation(
                        accounts: appState.slackAccountsViewModel?.accounts ?? [],
                        sharedAppAccountIDs: [],
                        liveStatuses: center.statuses,
                        isRunning: center.isRunning,
                        hasRead: center.hasRead,
                        lastError: center.lastError,
                        now: context.date),
                    checkAgain: { center.checkAgain() },
                    tryAgain: { Task { await center.reload() } })
            }
        }
    }

    private var workspaceSection: some View {
        SettingsSection(title: "Workspace") {
            HStack {
                Image(systemName: slackAuth.isConnected ? "checkmark.circle.fill" : "bolt.horizontal.circle")
                    .foregroundStyle(slackAuth.isConnected ? AnyShapeStyle(Tone.success) : AnyShapeStyle(.secondary))
                Text(slackAuth.isConnected ? "Slack connected" : "Slack not connected")
                Spacer()

                Button {
                    reconnectSlack()
                } label: {
                    HStack(spacing: Spacing.small) {
                        if flow.reconnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(flow.reconnecting
                            ? "Connecting..."
                            : (slackAuth.isConnected ? "Reconnect Slack" : "Connect Slack"))
                    }
                }
                .buttonStyle(.kitSecondary)
                .disabled(flow.reconnecting || flow.disconnecting)
                .managedByOrganization(sourceBlocked)

                if flow.reconnecting {
                    Button("Cancel") {
                        cancelSlackReconnect()
                    }
                    .buttonStyle(.kitSecondary)
                }

                if slackAuth.disconnectTarget != nil {
                    Button(role: .destructive) {
                        showSlackDisconnectConfirm = true
                    } label: {
                        HStack(spacing: Spacing.small) {
                            if flow.disconnecting {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(flow.disconnecting ? "Disconnecting..." : "Disconnect")
                        }
                    }
                    .buttonStyle(.kitDestructive)
                    .disabled(flow.reconnecting || flow.disconnecting)
                }
            }

            if let result = flow.reconnectResult {
                HStack {
                    Image(systemName: flow.reconnectSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(flow.reconnectSuccess ? Tone.success : Tone.error)
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(flow.reconnectSuccess ? Tone.success : Tone.error)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }

            if let err = slackAuth.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Tone.error)
            }

            if let notice = slackAuth.revokeNotice {
                SlackRevokeNoticeLine(text: notice)
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
            // `auth logout` is `slack remove` of account #1 (revoke, token
            // delete, row removed), so it says what the Remove dialog says.
            Text(AccountPurgeStatus.removeDialogMessage(
                slackAccount: disconnectName,
                status: appState.accountPurgeCenter?.status
            ))
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
            // phase. Same semantics as `slack remove` (revoke at Slack, data
            // kept for now, deleted 72 h later with the purge on).
            // Stop, disconnect and start as one item on the app's start queue.
            let daemon = flow.daemonManager
            let disconnected = await appState.disconnectSlackOnQueue(
                stop: { await daemon.stopDaemon() },
                disconnect: { await slackAuth.disconnect() },
                start: { await daemon.startDaemon() }
            )
            // Either way the config and the Workspaces list are re-read, so
            // a failed or partial disconnect never leaves them stale.
            config.reload()
            if disconnected { flow.reconnectResult = nil }
            await appState.slackAccountsViewModel?.refreshAsync()
            flow.disconnecting = false
        }
    }

    /// Slack Workspaces section — the multi-account Slack connections
    /// (`slack_accounts` table, migration 00048), each independently granting
    /// access via its own OAuth consent and carrying its own namespaced
    /// identity.
    ///
    /// The removal confirmation says what `slack remove` does: it revokes the
    /// token at Slack, drops the token file and marks the row removed/disabled;
    /// the synced data stays for now and, with the purge on, is deleted 72 h
    /// later (`AccountPurgeStatus.removeDialogMessage`). The legacy
    /// single-account Slack "Disconnect" in `workspaceSection` runs the same
    /// remove (`auth logout` → `removeSlackAccount`) and shows the same text.
    private var slackAccountsSection: some View {
        SettingsSection(title: "Slack Workspaces") {
            if let vm = appState.slackAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No Slack workspaces connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: Spacing.tight) {
                                Text(account.displayName)
                                if !account.teamDomain.isEmpty {
                                    Text("\(account.teamDomain).slack.com")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let note = account.syncNote {
                                    Label(note, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(Tone.warning)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let line = AccountPurgeLine.make(
                                    center: appState.accountPurgeCenter, source: "slack", accountID: Int64(account.id),
                                    isPurged: account.isPurged
                                ) {
                                    line
                                }
                            }
                            Spacer()
                            Circle()
                                .fill(slackAccountStatusColor(account))
                                .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                                .help(accountStatusHelp(account))
                            Toggle("Enabled", isOn: Binding(
                                get: { account.enabled },
                                set: { newValue in
                                    Task { await vm.setEnabled(account, enabled: newValue) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .disabled(vm.isConnecting || account.isPurged)
                            // Always offered: a healthy account re-consents to pick up a
                            // newly requested permission (sending, chat:write).
                            Button(account.isOK ? "Reconnect" : "Re-login") {
                                Task { await vm.relogin(account) }
                            }
                            .buttonStyle(.kitSecondary)
                            .managedByOrganization(sourceBlocked)
                            .help(
                                reloginBlocked(account.id)
                                    ?? "Sign in to this workspace again (grants new permissions such as sending messages)"
                            )
                            .disabled(vm.isConnecting || reloginBlocked(account.id) != nil)
                            Button("Rename…") {
                                accountBeingRenamed = AccountRenameTarget(id: account.id, currentName: account.displayName)
                            }
                            .buttonStyle(.kitQuiet)
                            .disabled(vm.isConnecting)
                            Button("Remove") {
                                slackAccountPendingRemoval = account
                            }
                            .buttonStyle(.kitQuiet)
                            .foregroundStyle(Tone.error)
                            .disabled(vm.isConnecting)
                        }
                    }
                }

                accountsFooter(vm)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddSlackAccountSheet) {
            // Settings opened during onboarding: its finish starts the
            // daemon, not this sheet.
            AddSlackAccountView(daemonPolicy: appState.accountDaemonPolicy)
                .environment(appState)
                .marksAccountSheet(appState)
        }
        .accountRenameAlert($accountBeingRenamed) { target, name in
            Task { await appState.slackAccountsViewModel?.rename(accountID: target.id, to: name) }
        }
        .confirmationDialog(
            "Remove \(slackAccountPendingRemoval?.displayName ?? "this workspace")?",
            isPresented: Binding(
                get: { slackAccountPendingRemoval != nil },
                set: { if !$0 { slackAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(AccountPurgeStatus.removeButton, role: .destructive) {
                if let account = slackAccountPendingRemoval {
                    Task { await appState.slackAccountsViewModel?.remove(account, daemonPolicy: appState.accountDaemonPolicy) }
                }
                slackAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountPurgeStatus.removeDialogMessage(
                slackAccount: slackAccountPendingRemoval?.displayName ?? "this workspace",
                status: appState.accountPurgeCenter?.status
            ))
        }
    }

    /// Under the Workspaces list: the last command's error, an unconfirmed
    /// revoke's notice, and Add.
    @ViewBuilder
    private func accountsFooter(_ vm: SlackAccountsViewModel) -> some View {
        if let err = vm.error {
            Text(err)
                .font(.caption)
                .foregroundStyle(Tone.error)
        }

        if let notice = vm.revokeNotice {
            SlackRevokeNoticeLine(text: notice)
        }

        Button("Add Slack Workspace") {
            showAddSlackAccountSheet = true
        }
        .buttonStyle(.kitSecondary)
        .managedByOrganization(sourceBlocked)
        .disabled(vm.isConnecting)
    }

    /// The dictionary editor lives only on the Reactions built-in's card (ask #366, C3).
    private var reactionDictionarySection: some View {
        SettingsSection(title: "Reaction commands") {
            HStack {
                Text("Reaction commands live in Automations → Built in → Reactions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open") {
                    appState.openBuiltinAutomation(BuiltinAutomationCard.reactionsID)
                    appState.bringMainWindowForward()
                }
                .buttonStyle(.kitSecondary)
            }
        }
    }

    /// Why Re-login is off for the account (its purge is running), or nil.
    private func reloginBlocked(_ id: Int) -> String? {
        AccountPurgeLine.reloginBlockedReason(
            center: appState.accountPurgeCenter, source: "slack", accountID: Int64(id))
    }

    private func slackAccountStatusColor(_ account: SlackAccount) -> Color {
        if account.isOK { return Tone.success }
        if account.isRevoked { return Tone.error }
        if account.isPurged { return Tone.status("gray") }
        return Tone.warning
    }

    private func accountStatusHelp(_ account: SlackAccount) -> String {
        if account.isOK { return "Connected" }
        if account.isPurged { return "Data deleted" }
        return account.error.isEmpty ? account.status : account.error
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
            // --app-return: the CLI brings the app back to the front once the
            // browser consent is done, and the page links back to it.
            process.arguments = ["auth", "login", "--app-return"]
            process.environment = await Constants.resolvedEnvironmentAsync()

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
        process.environment = await Constants.resolvedEnvironmentAsync()
        return await ProcessPipes.run(process).trimmed
    }
}
