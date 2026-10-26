import SwiftUI
import WatchtowerCore

/// Jira detail pane in the Connections tab — the multi-account Atlassian
/// connections (`jira_accounts` table, migration 00049), each independently
/// granting access via its own OAuth consent — and, once a site is
/// connected, its boards, Confluence spaces, features, user mapping and
/// sync (the Boards tab until #899). A board's profile and the features
/// detail open in place, with a way back.
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
    @State private var drillIn: JiraDetailItem?

    private var hasSites: Bool { appState.jiraAccountsViewModel?.accounts.isEmpty == false }

    var body: some View {
        if let drillIn {
            drillInContent(drillIn)
        } else {
            settingsForm
        }
    }

    private var settingsForm: some View {
        Form {
            jiraSettingsSection
            if hasSites {
                JiraBoardsSettingsView { board in withAnimation(Motion.panel) { drillIn = .board(board) } }
            }
            confluenceSections
            if hasSites {
                JiraFeaturesSettingsView { withAnimation(Motion.panel) { drillIn = .features } }
                JiraUserMappingSettingsView()
                JiraSyncInfoView()
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private func drillInContent(_ item: JiraDetailItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Spacing.regular) {
                Button {
                    withAnimation(Motion.panel) { drillIn = nil }
                } label: {
                    Label("Jira", systemImage: "chevron.left")
                }
                .buttonStyle(.kitQuiet)
                Text(item.title)
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, Spacing.medium)
            switch item {
            case .board(let board):
                JiraBoardProfileView(board: board)
                    .scrollContentBackground(.hidden)
            case .features:
                JiraFeaturesDetailView()
                    .scrollContentBackground(.hidden)
            }
        }
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

/// What opens in place of the Jira detail: a board's profile or the features detail.
enum JiraDetailItem: Hashable {
    case board(JiraBoard)
    case features

    var title: String {
        switch self {
        case .board(let board): board.name
        case .features: "Jira Features"
        }
    }
}
