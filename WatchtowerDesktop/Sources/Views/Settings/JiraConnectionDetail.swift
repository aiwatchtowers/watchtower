import SwiftUI
import WatchtowerCore

/// Jira detail pane in the Connections tab — the multi-account Atlassian
/// connections (`jira_accounts` table, migration 00049), each independently
/// granting access via its own OAuth consent.
///
/// Like Slack (and unlike Google), removal is non-destructive: `jira remove`
/// drops the token and marks the row removed/disabled but leaves
/// already-synced issues, boards, and releases in place.
struct JiraConnectionDetail: View {
    @Environment(AppState.self) private var appState
    /// The organization's policy forbids this source (#608): nothing new
    /// connects; existing accounts keep their data.
    private var sourceBlocked: Bool { !appState.managedPolicy.policy.sourceAllowed("jira") }
    @State private var showAddJiraAccountSheet = false
    @State private var jiraAccountPendingRemoval: JiraAccount?
    @State private var accountBeingRenamed: AccountRenameTarget?

    var body: some View {
        Form {
            jiraSettingsSection
            confluenceSections
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var jiraSettingsSection: some View {
        Section("Jira Sites") {
            if let vm = appState.jiraAccountsViewModel {
                if vm.accounts.isEmpty {
                    Text("No Jira sites connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.accounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName)
                                if !account.siteURL.isEmpty {
                                    Text(account.siteURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let line = AccountPurgeLine.make(
                                    center: appState.accountPurgeCenter, source: "jira", accountID: Int64(account.id),
                                    isPurged: account.isPurged
                                ) {
                                    line
                                }
                            }
                            Spacer()
                            Circle()
                                .fill(jiraAccountStatusColor(account))
                                .frame(width: 8, height: 8)
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
                            if !account.isOK {
                                Button("Re-login") {
                                    Task { await vm.relogin(account) }
                                }
                                .managedByOrganization(sourceBlocked)
                                .help(reloginBlocked(account.id) ?? "")
                                .disabled(vm.isConnecting || reloginBlocked(account.id) != nil)
                            }
                            Button("Rename…") {
                                accountBeingRenamed = AccountRenameTarget(id: account.id, currentName: account.displayName)
                            }
                            .buttonStyle(.plain)
                            .disabled(vm.isConnecting)
                            Button("Remove") {
                                jiraAccountPendingRemoval = account
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

                Button("Add Jira Site") {
                    showAddJiraAccountSheet = true
                }
                .managedByOrganization(sourceBlocked)
                .disabled(vm.isConnecting)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddJiraAccountSheet) {
            // Settings opened during onboarding: its finish starts the
            // daemon, not this sheet.
            AddJiraAccountView(daemonPolicy: appState.accountDaemonPolicy)
                .environment(appState)
                .marksAccountSheet(appState)
        }
        .accountRenameAlert($accountBeingRenamed) { target, name in
            Task { await appState.jiraAccountsViewModel?.rename(accountID: target.id, to: name) }
        }
        .confirmationDialog(
            "Remove \(jiraAccountPendingRemoval?.displayName ?? "this site")?",
            isPresented: Binding(
                get: { jiraAccountPendingRemoval != nil },
                set: { if !$0 { jiraAccountPendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Site", role: .destructive) {
                if let account = jiraAccountPendingRemoval {
                    Task { await appState.jiraAccountsViewModel?.remove(account, daemonPolicy: appState.accountDaemonPolicy) }
                }
                jiraAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountPurgeStatus.removeDialogMessage(
                "Disconnects the site. Already-synced issues, boards, and "
                    + "releases stay in Watchtower.",
                status: appState.accountPurgeCenter?.status
            ))
        }

        if appState.jiraAccountsViewModel?.accounts.isEmpty == false {
            Section {
                Button {
                    appState.selectedDestination = .boards
                } label: {
                    HStack {
                        Label(
                            "Manage Boards",
                            systemImage: "rectangle.on.rectangle.angled"
                        )
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// One Confluence spaces picker per enabled site — Confluence rides the
    /// Jira account's grant. The site name joins the header only when there
    /// is more than one to tell apart.
    @ViewBuilder
    private var confluenceSections: some View {
        let sites = appState.jiraAccountsViewModel?.accounts.filter(\.enabled) ?? []
        ForEach(sites) { account in
            ConfluenceSpacesSection(
                account: account,
                title: sites.count > 1 ? "Confluence — \(account.displayName)" : "Confluence"
            )
        }
    }

    /// Why Re-login is off for the account (its purge is running), or nil.
    private func reloginBlocked(_ id: Int) -> String? {
        AccountPurgeLine.reloginBlockedReason(
            center: appState.accountPurgeCenter, source: "jira", accountID: Int64(id))
    }

    private func jiraAccountStatusColor(_ account: JiraAccount) -> Color {
        if account.isOK { return .green }
        if account.isRevoked { return .red }
        if account.isPurged { return .gray }
        return .orange
    }

    private func accountStatusHelp(_ account: JiraAccount) -> String {
        if account.isOK { return "Connected" }
        if account.isPurged { return "Data deleted" }
        return account.error.isEmpty ? account.status : account.error
    }
}
