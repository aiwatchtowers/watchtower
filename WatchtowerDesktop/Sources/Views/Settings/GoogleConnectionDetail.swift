import DesignKit
import SwiftUI
import WatchtowerCore

/// Google detail pane in the Connections tab — the multi-account Calendar/Gmail
/// connections (`google_accounts` table) grouped by company (company screens
/// spec §4.2), under the shared-Google banner while Gmail still syncs on
/// Watchtower's shared app (§7), plus the global Calendar/Gmail sync
/// toggles, which apply across every connected Google account. No account
/// and no company: the §5.3 empty state.
struct GoogleConnectionDetail: View {
    @Environment(AppState.self) private var appState
    /// The organization's policy forbids this source (#608): nothing new
    /// connects; existing accounts keep their data.
    private var sourceBlocked: Bool { !appState.managedPolicy.policy.sourceAllowed("google") }
    @Bindable var config: ConfigService
    @State private var saveError: String?
    @State private var showAddGoogleAccountSheet = false
    @State private var googleAccountPendingRemoval: GoogleAccount?
    @State private var accountBeingRenamed: AccountRenameTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.large) {
                googleAccountsSections
                calendarSettingsSection
                gmailSettingsSection
                if let saveError {
                    // One caption for a failed autosave from either toggle.
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                }
            }
            .controlSize(.small)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .detailBackground()
        // A connect or Re-login turns the granted services' sync on from the
        // CLI (#740): show that instead of the switches this pane loaded.
        .onChange(of: appState.googleAccountsViewModel?.isConnecting ?? false) { wasConnecting, isConnecting in
            if wasConnecting && !isConnecting { config.adoptGoogleSyncSwitchesFromDisk() }
        }
        .sheet(isPresented: $showAddGoogleAccountSheet) {
            // Settings opened during onboarding: its finish starts the
            // daemon, not this sheet.
            AddGoogleAccountView(daemonPolicy: appState.accountDaemonPolicy)
                .environment(appState)
                .marksAccountSheet(appState)
        }
        .accountRenameAlert($accountBeingRenamed) { target, name in
            Task { await appState.googleAccountsViewModel?.rename(accountID: target.id, to: name) }
        }
        .confirmationDialog(
            "Remove \(googleAccountPendingRemoval?.displayName ?? "this account")?",
            isPresented: Binding(
                get: { googleAccountPendingRemoval != nil },
                set: { if !$0 { googleAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Account", role: .destructive) {
                if let account = googleAccountPendingRemoval {
                    Task { await appState.googleAccountsViewModel?.remove(account, daemonPolicy: appState.accountDaemonPolicy) }
                }
                googleAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Removes the connection, stops syncing, and deletes this account's synced mail and calendar "
                    + "events from this Mac. Events tied to a recording or recap are kept, and so are digests, "
                    + "briefings and other results built from them."
            )
        }
    }

    /// The banner, then the accounts grouped by company (or the loading,
    /// read-failed or empty state), then Add an account.
    private var googleAccountsSections: some View {
        let vm = appState.googleAccountsViewModel
        return CompanyAccountsSections(
            vendor: .google,
            banner: appState.companyBanner(.google),
            list: appState.companyAccountsList(.google),
            emptyActions: appState.companyDetailActions(.google, empty: true),
            addActions: appState.companyDetailActions(.google, empty: false),
            connect: appState.companyGroupConnect(blocked: sourceBlocked),
            blocked: sourceBlocked,
            busy: vm?.isConnecting ?? true,
            error: vm?.error,
            perform: perform,
            bannerAction: { action in
                if action == .useOwnGoogle { showAddGoogleAccountSheet = true } else { appState.performCompanyBannerAction(action) }
            },
            tryAgain: { vm?.refresh() },
            row: { ref in
                if let vm, let account = vm.accounts.first(where: { $0.id == ref.accountID }) {
                    accountRow(vm, account: account, ref: ref)
                }
            }
        )
    }

    /// **Use my own Google project** opens the add sheet with its custom
    /// client until Task 26's page replaces it.
    private func perform(_ kind: DetailAction.Kind) {
        if kind == .useOwnGoogle {
            showAddGoogleAccountSheet = true
        } else {
            appState.performCompanyDetailAction(kind, vendor: .google)
        }
    }

    private func accountRow(_ vm: GoogleAccountsViewModel, account: GoogleAccount, ref: AccountRef) -> some View {
        let status = appState.companyRowStatus(ref)
        return CompanyAccountRow(
            title: account.displayName,
            tag: CompanyConnectionsPresentation.tag(ref),
            status: status,
            line: CompanyConnectionsPresentation.googleRowLine(ref, calendar: account.calendarEnabled,
                                                               gmail: account.gmailEnabled),
            dot: statusColor(account),
            extra: AnyView(rowExtra(account, hasStatus: status != nil))
        ) {
            if let action = status?.action, action == .pasteCode {
                CompanyRowStatusButton(action: action, disabled: sourceBlocked) { _ in
                    appState.companyRowAction(action, account: ref)
                }
            } else if !account.isOK || status?.action == .relogin {
                // `google login --account` signs in through the account's own client (its company's after a Replace).
                Button(RowStatus.Action.relogin.title) {
                    vm.relogin(account, daemonPolicy: appState.accountDaemonPolicy)
                }
                .buttonStyle(.kitSecondary)
                .managedByOrganization(sourceBlocked)
                .help(reloginBlocked(account.id) ?? "")
                .disabled(vm.isConnecting || reloginBlocked(account.id) != nil)
            }
            Button("Rename…") {
                accountBeingRenamed = AccountRenameTarget(id: account.id, currentName: account.displayName)
            }
            .buttonStyle(.kitQuiet)
            .disabled(vm.isConnecting)
            Button("Remove") { googleAccountPendingRemoval = account }
                .buttonStyle(.kitQuiet)
                .foregroundStyle(Tone.error)
                .disabled(vm.isConnecting)
        }
    }

    /// The row's own lines under its status: the account's error (when no
    /// §4.3 status says it) and the purge line.
    @ViewBuilder
    private func rowExtra(_ account: GoogleAccount, hasStatus: Bool) -> some View {
        if !hasStatus, !account.isOK, !account.error.isEmpty {
            Text(account.error)
                .font(.caption)
                .foregroundStyle(Tone.error)
                .lineLimit(2)
        }
        if let line = AccountPurgeLine.make(
            center: appState.accountPurgeCenter, source: "google", accountID: Int64(account.id),
            isPurged: account.isPurged
        ) {
            line
        }
    }

    /// Why Re-login is off for the account (its purge is running), or nil.
    private func reloginBlocked(_ id: Int) -> String? {
        AccountPurgeLine.reloginBlockedReason(
            center: appState.accountPurgeCenter, source: "google", accountID: Int64(id))
    }

    private func statusColor(_ account: GoogleAccount) -> Color {
        if account.isOK { return Tone.success }
        if account.isRevoked { return Tone.error }
        if account.isPurged { return Tone.status("gray") }
        return Tone.warning
    }

    /// Global calendar-sync toggles only — connect/disconnect for individual
    /// Google accounts lives in the account sections above, since a
    /// workspace can have more than one Google account granting Calendar
    /// access.
    private var calendarSettingsSection: some View {
        SettingsSection(title: "Google Calendar") {
            Toggle("Enable calendar sync", isOn: $config.calendarEnabled)
                .onChange(of: config.calendarEnabled) { _, _ in saveSyncSwitchIfChanged() }

            Picker("Sync days ahead", selection: $config.calendarSyncDaysAhead) {
                Text("2 days").tag(2)
                Text("3 days").tag(3)
                Text("5 days").tag(5)
                Text("7 days").tag(7)
                Text("14 days").tag(14)
            }
            .fixedSize()
        }
    }

    /// Global Gmail-sync toggle only — connect/disconnect for individual
    /// Google accounts lives in the account sections above, since a
    /// workspace can have more than one Google account granting Gmail access.
    private var gmailSettingsSection: some View {
        SettingsSection(title: "Gmail") {
            Toggle("Enable Gmail sync", isOn: $config.gmailEnabled)
                .onChange(of: config.gmailEnabled) { _, _ in saveSyncSwitchIfChanged() }
        }
    }

    /// A switch adopted from disk after a connect needs no save; one the
    /// owner flipped does.
    private func saveSyncSwitchIfChanged() {
        if config.googleSyncSwitchesChanged { saveConfig() }
    }

    private func saveConfig() {
        do {
            try config.save()
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
    }
}
