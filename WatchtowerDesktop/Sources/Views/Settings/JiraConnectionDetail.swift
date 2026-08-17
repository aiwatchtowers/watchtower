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
    @State private var showAddJiraAccountSheet = false
    @State private var jiraAccountPendingRemoval: JiraAccount?

    var body: some View {
        Form {
            jiraSettingsSection
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
                            }
                            Spacer()
                            Circle()
                                .fill(jiraAccountStatusColor(account))
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
                .disabled(vm.isConnecting)
            } else {
                Text("Loading...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showAddJiraAccountSheet) {
            AddJiraAccountView()
                .environment(appState)
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
                    Task { await appState.jiraAccountsViewModel?.remove(account) }
                }
                jiraAccountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Disconnects the site. Already-synced issues, boards, and "
                    + "releases stay in Watchtower."
            )
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

    private func jiraAccountStatusColor(_ account: JiraAccount) -> Color {
        if account.isOK { return .green }
        if account.isRevoked { return .red }
        return .orange
    }
}
